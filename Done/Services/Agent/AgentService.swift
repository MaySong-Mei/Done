//
//  AgentService.swift
//  Done
//

import Foundation
import Combine
import SwiftUI
import os

private enum AgentDecisionDebugFileLogger {
    static let queue = DispatchQueue(label: "Done.AgentDecisionDebugFileLogger")
    static var announcedPath = false
    static let maxBytes = 512 * 1024
    static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Done",
        category: "AgentDecisionDebug"
    )

    static func append(line: String) {
        queue.async {
            let fileURL = logFileURL()
            do {
                let directory = fileURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

                if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
                   let fileSize = attrs[.size] as? NSNumber,
                   fileSize.intValue > maxBytes {
                    let rotated = fileURL.deletingPathExtension().appendingPathExtension("old.log")
                    try? FileManager.default.removeItem(at: rotated)
                    try? FileManager.default.moveItem(at: fileURL, to: rotated)
                }

                if !FileManager.default.fileExists(atPath: fileURL.path) {
                    try Data().write(to: fileURL, options: .atomic)
                }

                let data = Data((line + "\n").utf8)
                if let handle = try? FileHandle(forWritingTo: fileURL) {
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                    try? handle.close()
                } else {
                    try data.write(to: fileURL, options: .atomic)
                }

                if !announcedPath {
                    announcedPath = true
                    logger.info("file=\(fileURL.path, privacy: .public)")
                }
            } catch {
                logger.error("file_write_error=\(error.localizedDescription, privacy: .public)")
            }
        }
    }

    static func logFileURL() -> URL {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return appSupport
            .appendingPathComponent("AgentRuntime", isDirectory: true)
            .appendingPathComponent("agent_decision_debug.log")
    }
}

func agentDecisionDebugLog(_ message: @autoclosure () -> String) {
#if DEBUG
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let line = "\(formatter.string(from: Date())) [AgentDecisionDebug] \(message())"
    print(line)
    AgentDecisionDebugFileLogger.append(line: line)
#endif
}

private func agentDecisionDebugSnippet(_ text: String, limit: Int = 220) -> String {
    let flattened = text.replacingOccurrences(of: "\n", with: " ")
    if flattened.count <= limit { return flattened }
    return String(flattened.prefix(limit)) + "…"
}

final class AgentService: ObservableObject {
    @Published var conversations: [AgentConversation] = []
    @Published var currentConversationID: UUID?
    @Published var messages: [ChatMessage] = []
    @Published var isProcessing: Bool = false

    weak var eventStore: EventStore?
    weak var agentRuntime: AgentRuntime?

    /// gh#135: staged destructive actions awaiting the user's Confirm/Cancel.
    /// The chat views observe this registry directly (nested ObservableObject
    /// — this service does not republish its changes).
    let pendingDestructiveActions = AgentPendingActionRegistry()

    private let maxToolRounds = 5

    /// Where the chat history actually lives. `AgentService` is `@StateObject`ed
    /// in several views, so it was never the owner of these bytes — it just
    /// happened to share them through `UserDefaults` with the sync, snapshot
    /// and restore paths. The repository is that shared owner made explicit,
    /// and durable.
    private let repository: AgentConversationRepository

    /// The other half of "one owner rather than N caches".
    ///
    /// Naming an owner only fixes the READ side. `AgentChatView` and
    /// `CalendarEventChatView` each `@StateObject` their own `AgentService`,
    /// each of which copied `repository.conversations` once at init and then
    /// wrote its whole array back on every save — so anything that moved the
    /// file underneath a live service was reverted by that service's next
    /// keystroke. Concretely, and all three were reproducible:
    ///
    /// * a restore lands the cloud copy, the open chat view still renders the
    ///   pre-restore array, and its next round writes that array over the
    ///   restored file — then `didChangeNotification` wakes the sync sink,
    ///   which uploads the clobber over the cloud copy the restore came from.
    ///   That is the sharpest one, because a user-confirmed restore is the
    ///   ONLY exit from a freeze, and a frozen session is by definition one
    ///   with a chat view open;
    /// * "reset all local data" wipes the file and the next round resurrects
    ///   what the user asked to erase;
    /// * typing in the event sheet after typing in the chat tab drops the
    ///   tab's conversation.
    ///
    /// So the cache follows the owner: the repository already posts on every
    /// real commit, and this is the subscription that had been missing on
    /// this side of it.
    private var repositoryObserver: AnyCancellable?

    init(repository: AgentConversationRepository = .shared) {
        self.repository = repository
        loadConversations()
        // Deliberately synchronous (no `receive(on:)`): the repository is
        // `@MainActor`, so every post already arrives on the main thread, and
        // a hop would leave a window in which this cache is known-stale and
        // still writable.
        repositoryObserver = NotificationCenter.default
            .publisher(for: AgentConversationRepository.didChangeNotification, object: repository)
            .sink { [weak self] _ in
                self?.adoptRepositoryState()
            }
    }

    // MARK: - Computed

    var currentConversation: AgentConversation? {
        conversations.first { $0.id == currentConversationID }
    }

    // MARK: - Public API

    func sendMessage(_ text: String) {
        ensureCurrentConversation()
        agentDecisionDebugLog("User.sendMessage conversationID=\(currentConversationID?.uuidString ?? "nil") text=\(agentDecisionDebugSnippet(text))")

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
        agentDecisionDebugLog("AgentService.processConversation start conversationID=\(currentConversationID?.uuidString ?? "nil")")
        guard let store = eventStore else {
            agentDecisionDebugLog("AgentService.processConversation abort: missing EventStore")
            removeLoadingMessage()
            appendAssistantMessage("Error: EventStore not available.")
            isProcessing = false
            return
        }

        let provider: (any LLMProvider)?
        do {
            provider = try buildProvider()
        } catch {
            agentDecisionDebugLog("AgentService.processConversation provider error: \(error.localizedDescription)")
            removeLoadingMessage()
            appendAssistantMessage("Error: \(error.localizedDescription)")
            isProcessing = false
            return
        }

        guard let provider else {
            agentDecisionDebugLog("AgentService.processConversation provider creation returned nil")
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
                systemPrompt: buildSystemPrompt(store: store),
                purpose: "chat"
            )

            let response: LLMResponse
            do {
                response = try await provider.send(request)
            } catch {
                agentDecisionDebugLog("AgentService.processConversation LLM send error: \(error.localizedDescription)")
                removeLoadingMessage()
                appendAssistantMessage("Error: \(error.localizedDescription)")
                isProcessing = false
                return
            }

            agentDecisionDebugLog(
                "LLM response received: toolCalls=\(response.toolCalls.count) content=\(agentDecisionDebugSnippet(response.content ?? "<nil>"))"
            )

            if !response.toolCalls.isEmpty {
                removeLoadingMessage()

                if let text = response.content, !text.isEmpty {
                    appendAssistantMessage(text)
                }

                for toolCall in response.toolCalls {
                    agentDecisionDebugLog("Tool call start: name=\(toolCall.name), id=\(toolCall.id), args=\(agentDecisionDebugSnippet(toolCall.arguments))")
                    var toolCallMsg = ChatMessage(
                        role: .toolCall,
                        content: toolCall.arguments,
                        toolName: toolCall.name,
                        toolCallId: toolCall.id
                    )

                    let result = AgentToolRunner.execute(
                        toolName: toolCall.name,
                        arguments: toolCall.arguments,
                        store: store,
                        pendingActions: pendingDestructiveActions
                    )
                    agentDecisionDebugLog("Tool call result: name=\(toolCall.name), result=\(agentDecisionDebugSnippet(result))")

                    // Extract event IDs from tool calls
                    let eventIDs = extractEventIDs(
                        toolName: toolCall.name,
                        arguments: toolCall.arguments,
                        result: result
                    )
                    agentDecisionDebugLog("Extracted eventIDs for \(toolCall.name): \(eventIDs.map(\.uuidString))")
                    if !eventIDs.isEmpty {
                        toolCallMsg.referencedEventIDs = eventIDs
                        trackEventIDs(eventIDs, store: store)
                        enqueuePostToolClassificationReview(
                            toolName: toolCall.name,
                            eventIDs: eventIDs,
                            store: store
                        )
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
                agentDecisionDebugLog("LLM final response text=\(agentDecisionDebugSnippet(text))")
                appendAssistantMessage(text)
            }
            break
        }

        // If the loop exited by exhausting `roundsRemaining` (not via the
        // `break` above), a trailing loading message is still queued — clear it
        // so the spinner doesn't stick in the live message list.
        removeLoadingMessage()
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
            } else {
                agentDecisionDebugLog("extractEventIDs failed for \(toolName): no top-level id in result=\(agentDecisionDebugSnippet(result))")
            }
        case "updateTodo", "completeTodo", "deleteTodo", "deleteCalendarEvent":
            // Parse id from arguments JSON
            if let data = arguments.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let idStr = json["id"] as? String,
               let uuid = UUID(uuidString: idStr) {
                ids.append(uuid)
            } else {
                agentDecisionDebugLog("extractEventIDs failed for \(toolName): no id in arguments=\(agentDecisionDebugSnippet(arguments))")
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
            } else if let event = store.findCalendarEvent(id: id) {
                conversations[idx].involvedEventNames[id] = event.title
            }
        }
    }

    private func enqueuePostToolClassificationReview(
        toolName: String,
        eventIDs: [UUID],
        store: EventStore
    ) {
        guard !eventIDs.isEmpty else { return }
        guard ["createTodo", "createCalendarEvent", "updateTodo"].contains(toolName) else { return }

        let conversationID = currentConversationID
        let runtime = agentRuntime
        if runtime == nil {
            agentDecisionDebugLog("Post-tool classification review skipped: agentRuntime is nil, tool=\(toolName), eventIDs=\(eventIDs.map(\.uuidString))")
        } else {
            agentDecisionDebugLog("Queueing post-tool classification review: tool=\(toolName), eventIDs=\(eventIDs.map(\.uuidString))")
        }
        Task { @MainActor in
            guard let runtime else { return }
            for eventID in eventIDs {
                if let event = store.findCalendarEvent(id: eventID) {
                    agentDecisionDebugLog("Post-tool review evaluating calendar event id=\(eventID.uuidString), type='\(event.type)'")
                    let context = AgentDecisionContext(
                        domain: .chat,
                        operationID: UUID(),
                        sourceScreen: "AgentChat",
                        conversationID: conversationID,
                        relatedEventIDs: [eventID],
                        payloadSummary: "Post-tool review for \(toolName)",
                        metadata: [
                            "candidateType": event.type,
                            "eventKind": "calendar",
                            "toolName": toolName
                        ]
                    )
                    Task {
                        agentDecisionDebugLog("Post-tool review calling operationCenter for calendar event id=\(eventID.uuidString)")
                        await runtime.operationCenter.maybeHandleMissingEventTypeTemplate(
                            for: eventID,
                            isCalendarEvent: true,
                            proposedType: event.type,
                            store: store,
                            context: context
                        )
                    }
                } else if let event = store.events.first(where: { $0.id == eventID }) {
                    agentDecisionDebugLog("Post-tool review evaluating todo event id=\(eventID.uuidString), type='\(event.type)'")
                    let context = AgentDecisionContext(
                        domain: .chat,
                        operationID: UUID(),
                        sourceScreen: "AgentChat",
                        conversationID: conversationID,
                        relatedEventIDs: [eventID],
                        payloadSummary: "Post-tool review for \(toolName)",
                        metadata: [
                            "candidateType": event.type,
                            "eventKind": "todo",
                            "toolName": toolName
                        ]
                    )
                    Task {
                        agentDecisionDebugLog("Post-tool review calling operationCenter for todo event id=\(eventID.uuidString)")
                        await runtime.operationCenter.maybeHandleMissingEventTypeTemplate(
                            for: eventID,
                            isCalendarEvent: false,
                            proposedType: event.type,
                            store: store,
                            context: context
                        )
                    }
                } else {
                    agentDecisionDebugLog("Post-tool review could not find event in stores for id=\(eventID.uuidString)")
                }
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
                systemPrompt: "You generate short conversation titles. Respond with only the title text, nothing else.",
                purpose: "chat"
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

    private func buildSystemPrompt(store: EventStore, templateStore: EventTypeTemplateStore = EventTypeTemplateStore()) -> String {
        let now = Date()
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .short

        let activeTodoCount = store.activeEvents.count
        let completedTodoCount = store.completedCount
        // canvasRenderableCalendarEvents: matches what the user sees
        // on the canvas. Reporting raw would tell the LLM "you have N
        // calendar events" where N silently includes absorbed-into-
        // parent todos, inflating the agent's mental model of user
        // load.
        let calendarEventCount = store.canvasRenderableCalendarEvents.count

        let typeNames = templateStore.templates.map(\.title)
        let typeList = typeNames.isEmpty ? "Study, Work, Exercise, Sleep" : typeNames.joined(separator: ", ")

        return """
        You are a helpful AI assistant and personal productivity coach for the "Done" productivity app. You help users manage their todos and calendar events, and provide behavioral insights.

        Current time: \(formatter.string(from: now))

        Current stats:
        - Active todos: \(activeTodoCount)
        - Completed todos: \(completedTodoCount)
        - Calendar events: \(calendarEventCount)

        Available event types: [\(typeList)]

        Guidelines:
        - Use the provided tools to create, read, update, and delete todos and calendar events.
        - Deletion is two-step: deleteTodo and deleteCalendarEvent only STAGE a deletion — the user must confirm it on a card shown in the app. After calling them, say the deletion awaits the user's confirmation; never claim the item was already deleted.
        - When the user wants to create an event with a specific time, use createCalendarEvent.
        - When the user wants to create a task without a specific time, use createTodo.
        - Always confirm what you've done after performing an action.
        - Be concise and helpful.
        - For dates, use ISO8601 format (yyyy-MM-dd'T'HH:mm:ss) when calling tools.
        - If the user mentions a relative time (like "tomorrow 3pm"), calculate the actual date/time based on the current time.
        - If the user explicitly specifies an event type/category label (for example "type use PaperReading"), preserve that label in tool arguments unless it is clearly invalid.
        - When setting event types, you MUST use one of the available event types listed above. Do NOT invent new type names or use types that are not in the list.
        - Respond in the same language the user uses.

        Behavioral analysis:
        - When the user asks about their habits, patterns, productivity, personality, or wants advice on scheduling, use the getUserData tool to fetch their raw data.
        - Analyze the data yourself to provide personalized insights: chronotype, peak hours, work-life balance, consistency, energy patterns, etc.
        - Be warm, insightful, and specific. Back up observations with actual data.
        - Don't just list numbers — interpret them into meaningful insights and actionable suggestions.
        """
    }

    private func buildLLMMessages() -> [LLMMessage] {
        let filtered = messages.filter { !$0.isLoading }
        var llmMessages: [LLMMessage] = []

        for (index, msg) in filtered.enumerated() {
            switch msg.role {
            case .user:
                llmMessages.append(LLMMessage(role: .user, content: msg.content))

            case .assistant:
                // Collect subsequent toolCall messages that belong to this assistant turn
                let toolCalls: [LLMToolCall] = filtered.dropFirst(index + 1)
                    .prefix(while: { $0.role == .toolCall })
                    .map { tc in
                        LLMToolCall(
                            id: tc.toolCallId ?? UUID().uuidString,
                            name: tc.toolName ?? "",
                            arguments: tc.content
                        )
                    }

                llmMessages.append(LLMMessage(
                    role: .assistant,
                    content: msg.content,
                    toolCalls: toolCalls.isEmpty ? nil : toolCalls
                ))

            case .toolCall:
                // Only emit a synthetic assistant message for orphaned toolCalls
                // (those not preceded by an assistant message that already collected them)
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
        }

        return llmMessages
    }

    // MARK: - Provider

    private func buildProvider() throws -> any LLMProvider {
        let providerType = UserDefaults.standard.string(forKey: AppSettingsKeys.agentProvider) ?? AppSettingsKeys.agentProviderDefault
        let apiKey = UserDefaults.standard.string(forKey: AppSettingsKeys.agentAPIKey) ?? ""

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

    // MARK: - Pending Destructive Actions (gh#135)

    /// Executes the staged deletion through the registry — the UI's Confirm
    /// button lands here and NOWHERE closer to the store. `nonce` is the
    /// nonce of the action THE CARD RENDERED: re-reading the registry's
    /// current pending at tap time would make the nonce guard vacuous — a
    /// tap consented to card A could execute a just-replaced staging B. The
    /// outcome is appended as an assistant message so the transcript (and
    /// the model, on its next turn) reflects what actually happened.
    func confirmPendingDestructiveAction(nonce: UUID) {
        guard let store = eventStore else { return }
        switch pendingDestructiveActions.confirm(nonce: nonce, store: store) {
        case .deleted(let title):
            appendAssistantMessage("Deleted '\(title)' after your confirmation.")
        case .refused(let reason):
            appendAssistantMessage(reason)
        }
    }

    /// Discards the staged deletion without touching the store. Same rule:
    /// `nonce` is the rendered card's, never re-read at tap time, so a
    /// stale Cancel cannot discard a newer staging.
    func cancelPendingDestructiveAction(nonce: UUID) {
        if let discarded = pendingDestructiveActions.cancel(nonce: nonce) {
            appendAssistantMessage("Cancelled — '\(discarded.displayTitle)' was not deleted.")
        }
    }

    private func appendAssistantMessage(_ text: String) {
        agentDecisionDebugLog("Assistant.appendMessage text=\(agentDecisionDebugSnippet(text))")
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

    /// Both decodes, both legacy keys and the stale-loading-message cleanup all
    /// moved into `AgentConversationRepository`, where the difference between
    /// "no history", "history we could not read" and "history in the older
    /// encoding" can be told apart — here they all collapsed into the same
    /// empty array, and the sync row builder then uploaded it.
    private func loadConversations() {
        conversations = repository.conversations
        if let first = conversations.first {
            currentConversationID = first.id
            messages = first.messages
        }
    }

    private func saveConversations() {
        // The failure is the repository's to report (`DiagnosticTrail`, the
        // degraded flag) — what matters here is that it is no longer swallowed
        // by a `catch {}` that made an unwritten 351 KB transcript look saved.
        repository.replaceAll(conversations)
    }

    /// Re-read the owner after it changed under us — a restore, a wipe, or the
    /// other view's `AgentService` committing a round. See `repositoryObserver`.
    ///
    /// Our OWN commit posts too, and lands here with the repository holding
    /// exactly what we just handed it, so the equality check is what makes this
    /// a no-op on the common path rather than a rebuild per keystroke. It is
    /// also why a refused write cannot reach in and empty the composer: a
    /// frozen repository does not post at all, and a write that merely failed
    /// leaves the repository holding our array.
    private func adoptRepositoryState() {
        let incoming = repository.conversations
        guard incoming != conversations else { return }
        conversations = incoming

        if let id = currentConversationID, let surviving = incoming.first(where: { $0.id == id }) {
            // A round in flight owns `messages` — it holds the loading
            // placeholder and the reply being assembled — so an unrelated
            // change elsewhere in the array must not rebuild it underneath.
            guard !isProcessing else { return }
            messages = surviving.messages
        } else {
            // The conversation we were in did not survive: a restore or a wipe
            // replaced the whole array. Land where a launch would.
            currentConversationID = incoming.first?.id
            messages = incoming.first?.messages ?? []
        }
    }
}

// MARK: - Agent Operating Runtime (Phase 1)

enum AgentDecisionKind: String, Codable, Hashable {
    case missingEventTypeTemplate
}

enum AgentDecisionDomain: String, Codable, Hashable {
    case calendar
    case todo
    case chat
    case analysis
}

struct AgentDecisionDefaultPolicy: Codable, Hashable {
    enum Kind: String, Codable, Hashable {
        case noOpContinue
        case applyOption
        case cancelOperation
    }

    var kind: Kind
    var optionID: String?

    static let noOpContinue = AgentDecisionDefaultPolicy(kind: .noOpContinue, optionID: nil)
    static let cancelOperation = AgentDecisionDefaultPolicy(kind: .cancelOperation, optionID: nil)

    static func applyOption(_ optionID: String) -> AgentDecisionDefaultPolicy {
        AgentDecisionDefaultPolicy(kind: .applyOption, optionID: optionID)
    }
}

struct AgentDecisionOption: Identifiable, Codable, Hashable {
    var id: String
    var title: String
    var subtitle: String?
    var effectPreview: String?
    var isRecommended: Bool

    init(
        id: String,
        title: String,
        subtitle: String? = nil,
        effectPreview: String? = nil,
        isRecommended: Bool = false
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.effectPreview = effectPreview
        self.isRecommended = isRecommended
    }
}

struct AgentDecisionContext: Codable, Hashable {
    var domain: AgentDecisionDomain
    var operationID: UUID
    var sourceScreen: String
    var conversationID: UUID?
    var relatedEventIDs: [UUID]
    var payloadSummary: String
    var metadata: [String: String]

    init(
        domain: AgentDecisionDomain,
        operationID: UUID,
        sourceScreen: String,
        conversationID: UUID? = nil,
        relatedEventIDs: [UUID] = [],
        payloadSummary: String,
        metadata: [String: String] = [:]
    ) {
        self.domain = domain
        self.operationID = operationID
        self.sourceScreen = sourceScreen
        self.conversationID = conversationID
        self.relatedEventIDs = relatedEventIDs
        self.payloadSummary = payloadSummary
        self.metadata = metadata
    }
}

struct AgentDecisionRequest: Identifiable, Codable, Hashable {
    var id: UUID
    var kind: AgentDecisionKind
    var title: String
    var message: String
    var options: [AgentDecisionOption]
    var recommendedOptionID: String?
    var otherwiseEnabled: Bool
    var defaultPolicy: AgentDecisionDefaultPolicy
    var timeout: TimeInterval?
    var context: AgentDecisionContext
    var createdAt: Date

    init(
        id: UUID = UUID(),
        kind: AgentDecisionKind,
        title: String,
        message: String,
        options: [AgentDecisionOption],
        recommendedOptionID: String? = nil,
        otherwiseEnabled: Bool = true,
        defaultPolicy: AgentDecisionDefaultPolicy = .noOpContinue,
        timeout: TimeInterval? = nil,
        context: AgentDecisionContext,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.message = message
        self.options = options
        self.recommendedOptionID = recommendedOptionID
        self.otherwiseEnabled = otherwiseEnabled
        self.defaultPolicy = defaultPolicy
        self.timeout = timeout
        self.context = context
        self.createdAt = createdAt
    }
}

enum AgentDecisionResult: Hashable {
    case selected(optionID: String)
    case otherwise(text: String)
    case timedOut
    case dismissed
    case cancelled
}

enum AgentDecisionEffectiveOutcome: Hashable {
    case noOpContinue
    case applyOption(String)
    case otherwise(String)
    case cancelOperation
}

struct AgentDecisionResolution: Hashable {
    var request: AgentDecisionRequest
    var result: AgentDecisionResult
    var effectiveOutcome: AgentDecisionEffectiveOutcome
    var wasDefaulted: Bool
}

enum AgentDecisionRecordResultKind: String, Codable, Hashable {
    case selected
    case otherwise
    case timedOut
    case dismissed
    case cancelled
}

struct AgentDecisionRecord: Identifiable, Codable, Hashable {
    var id: UUID
    var requestSnapshot: AgentDecisionRequest
    var resultKind: AgentDecisionRecordResultKind
    var selectedOptionID: String?
    var otherwiseText: String?
    var resolvedAt: Date
    var appliedActionSummary: String
    var wasDefaulted: Bool
    var preferenceSignal: String?

    init(
        id: UUID = UUID(),
        requestSnapshot: AgentDecisionRequest,
        resultKind: AgentDecisionRecordResultKind,
        selectedOptionID: String? = nil,
        otherwiseText: String? = nil,
        resolvedAt: Date = Date(),
        appliedActionSummary: String,
        wasDefaulted: Bool,
        preferenceSignal: String? = nil
    ) {
        self.id = id
        self.requestSnapshot = requestSnapshot
        self.resultKind = resultKind
        self.selectedOptionID = selectedOptionID
        self.otherwiseText = otherwiseText
        self.resolvedAt = resolvedAt
        self.appliedActionSummary = appliedActionSummary
        self.wasDefaulted = wasDefaulted
        self.preferenceSignal = preferenceSignal
    }
}

enum AgentPreferenceScope: String, Codable, Hashable {
    case eventTypeMapping
    case confirmationPreference
    case classificationPolicy
}

enum AgentPreferenceSource: String, Codable, Hashable {
    case explicitSelection
    case otherwiseText
}

struct AgentPreferenceTrigger: Codable, Hashable {
    enum Kind: String, Codable, Hashable {
        case exactEventTypeTitle
    }

    var kind: Kind
    var value: String
}

enum AgentPreferenceActionKind: String, Codable, Hashable {
    case createTypeTemplate
    case keepTypeOnly
    case useExistingType
    case customInstruction
}

struct AgentPreferenceAction: Codable, Hashable {
    var kind: AgentPreferenceActionKind
    var value: String?
}

struct AgentPreferenceRule: Identifiable, Codable, Hashable {
    var id: UUID
    var scope: AgentPreferenceScope
    var triggerPattern: AgentPreferenceTrigger
    var preferredAction: AgentPreferenceAction
    var source: AgentPreferenceSource
    var evidenceCount: Int
    var lastUsedAt: Date
    var isEnabled: Bool

    init(
        id: UUID = UUID(),
        scope: AgentPreferenceScope,
        triggerPattern: AgentPreferenceTrigger,
        preferredAction: AgentPreferenceAction,
        source: AgentPreferenceSource,
        evidenceCount: Int = 1,
        lastUsedAt: Date = Date(),
        isEnabled: Bool = true
    ) {
        self.id = id
        self.scope = scope
        self.triggerPattern = triggerPattern
        self.preferredAction = preferredAction
        self.source = source
        self.evidenceCount = evidenceCount
        self.lastUsedAt = lastUsedAt
        self.isEnabled = isEnabled
    }
}

enum AgentOperationPhase: String, Codable, Hashable {
    case started
    case waitingDecision
    case resumed
    case succeeded
    case failed
    case defaulted
}

struct AgentOperationEvent: Identifiable, Codable, Hashable {
    var id: UUID
    var operationID: UUID
    var phase: AgentOperationPhase
    var message: String
    var timestamp: Date
    var relatedEventID: UUID?
    var decisionID: UUID?

    init(
        id: UUID = UUID(),
        operationID: UUID,
        phase: AgentOperationPhase,
        message: String,
        timestamp: Date = Date(),
        relatedEventID: UUID? = nil,
        decisionID: UUID? = nil
    ) {
        self.id = id
        self.operationID = operationID
        self.phase = phase
        self.message = message
        self.timestamp = timestamp
        self.relatedEventID = relatedEventID
        self.decisionID = decisionID
    }
}

enum AgentClassificationOutcome: Equatable {
    case skipped(reason: String)
    case createdTemplate(title: String)
    case keptEventTypeOnly
    case updatedEventType(to: String)
    case defaultedNoTemplate
    case failed(message: String)
}

@MainActor
final class AgentPreferenceStore: ObservableObject {
    @Published private(set) var rules: [AgentPreferenceRule] = []
    @Published private(set) var decisionHistory: [AgentDecisionRecord] = []

    private let fileManager: FileManager
    private let directoryURL: URL
    private let decisionsURL: URL
    private let rulesURL: URL
    private let historyLimit = 300

    init(
        directoryURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        if let directoryURL {
            self.directoryURL = directoryURL
        } else {
            let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.directoryURL = appSupport.appendingPathComponent("AgentRuntime", isDirectory: true)
        }
        self.decisionsURL = self.directoryURL.appendingPathComponent("decision_records.json")
        self.rulesURL = self.directoryURL.appendingPathComponent("preference_rules.json")
        load()
    }

    func recordDecision(_ record: AgentDecisionRecord) {
        decisionHistory.insert(record, at: 0)
        if decisionHistory.count > historyLimit {
            decisionHistory = Array(decisionHistory.prefix(historyLimit))
        }

        if let newRule = makeRule(from: record) {
            upsertRule(newRule)
        }

        save()
    }

    func listRules() -> [AgentPreferenceRule] {
        rules
            .filter(\.isEnabled)
            .sorted { $0.lastUsedAt > $1.lastUsedAt }
    }

    func clearRules() {
        rules = []
        saveRules()
    }

    func clearDecisionHistory() {
        decisionHistory = []
        saveDecisions()
    }

    /// Apply a cloud restore snapshot. AgentPreferenceStore is a "blob"
    /// table — one row per user holding rules + history together — so
    /// `merge.keepLocal` is a no-op and the other paths replace both
    /// arrays atomically. Per-row conflict UI doesn't apply here (there
    /// is only one logical row).
    func applyRestore(
        rules cloudRules: [AgentPreferenceRule],
        decisionHistory cloudDecisions: [AgentDecisionRecord],
        strategy: RestoreStrategy,
        resolution: ConflictResolution
    ) {
        switch strategy {
        case .cloudOverwritesLocal:
            rules = cloudRules
            decisionHistory = cloudDecisions
            save()
        case .merge:
            if resolution == .keepCloud {
                rules = cloudRules
                decisionHistory = cloudDecisions
                save()
            }
            // .keepLocal — preserve what's on disk; no-op.
        }
    }

    func shouldSuppressMissingTypePrompt(for normalizedType: String, now: Date = Date()) -> Bool {
        let cutoff = now.addingTimeInterval(-30 * 24 * 3600)
        let matching = rules.filter {
            $0.isEnabled &&
            $0.scope == .classificationPolicy &&
            $0.triggerPattern.kind == .exactEventTypeTitle &&
            $0.triggerPattern.value == normalizedType &&
            $0.preferredAction.kind == .keepTypeOnly &&
            $0.lastUsedAt >= cutoff
        }
        let evidence = matching.reduce(0) { $0 + $1.evidenceCount }
        return evidence >= 3
    }

    func prefersCreateTemplateRecommendation(for normalizedType: String) -> Bool {
        let matching = rules.filter {
            $0.isEnabled &&
            $0.scope == .classificationPolicy &&
            $0.triggerPattern.kind == .exactEventTypeTitle &&
            $0.triggerPattern.value == normalizedType &&
            $0.preferredAction.kind == .createTypeTemplate
        }
        let evidence = matching.reduce(0) { $0 + $1.evidenceCount }
        return evidence >= 2
    }

    private func load() {
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
        } catch {
            // Best-effort local persistence.
        }
        rules = loadJSON([AgentPreferenceRule].self, from: rulesURL) ?? []
        decisionHistory = loadJSON([AgentDecisionRecord].self, from: decisionsURL) ?? []
    }

    private func save() {
        saveRules()
        saveDecisions()
    }

    private func saveRules() {
        saveJSON(rules, to: rulesURL)
    }

    private func saveDecisions() {
        saveJSON(decisionHistory, to: decisionsURL)
    }

    private func loadJSON<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func saveJSON<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(value)
            try data.write(to: url, options: .atomic)
        } catch {
            // Best-effort local persistence.
        }
    }

    private func upsertRule(_ incoming: AgentPreferenceRule) {
        if let index = rules.firstIndex(where: {
            $0.scope == incoming.scope &&
            $0.triggerPattern == incoming.triggerPattern &&
            $0.preferredAction == incoming.preferredAction &&
            $0.source == incoming.source
        }) {
            rules[index].evidenceCount += incoming.evidenceCount
            rules[index].lastUsedAt = incoming.lastUsedAt
            rules[index].isEnabled = true
        } else {
            rules.insert(incoming, at: 0)
        }
    }

    private func makeRule(from record: AgentDecisionRecord) -> AgentPreferenceRule? {
        guard !record.wasDefaulted else { return nil } // explicit-feedback only
        guard record.requestSnapshot.kind == .missingEventTypeTemplate else { return nil }
        guard let candidateType = record.requestSnapshot.context.metadata["candidateType"] else { return nil }
        let normalized = EventTypeTemplateStore.normalizedTitle(candidateType)
        guard !normalized.isEmpty else { return nil }

        let trigger = AgentPreferenceTrigger(kind: .exactEventTypeTitle, value: normalized)

        switch record.resultKind {
        case .selected:
            guard let selectedOptionID = record.selectedOptionID else { return nil }
            switch selectedOptionID {
            case AgentOperationCenter.OptionID.createTemplate:
                return AgentPreferenceRule(
                    scope: .classificationPolicy,
                    triggerPattern: trigger,
                    preferredAction: AgentPreferenceAction(kind: .createTypeTemplate, value: nil),
                    source: .explicitSelection
                )
            case AgentOperationCenter.OptionID.keepTypeOnly:
                return AgentPreferenceRule(
                    scope: .classificationPolicy,
                    triggerPattern: trigger,
                    preferredAction: AgentPreferenceAction(kind: .keepTypeOnly, value: nil),
                    source: .explicitSelection
                )
            default:
                return nil
            }
        case .otherwise:
            let text = (record.otherwiseText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return AgentPreferenceRule(
                scope: .eventTypeMapping,
                triggerPattern: trigger,
                preferredAction: AgentPreferenceAction(kind: .customInstruction, value: text),
                source: .otherwiseText
            )
        case .timedOut, .dismissed, .cancelled:
            return nil
        }
    }

    private func formatRuleSummary(_ rule: AgentPreferenceRule) -> String {
        let trigger = rule.triggerPattern.value
        switch rule.preferredAction.kind {
        case .createTypeTemplate:
            return "\"\(trigger)\" -> prefer creating type template (\(rule.evidenceCount)x)"
        case .keepTypeOnly:
            return "\"\(trigger)\" -> prefer keeping event type only (\(rule.evidenceCount)x)"
        case .useExistingType:
            return "\"\(trigger)\" -> use \(rule.preferredAction.value ?? "existing type") (\(rule.evidenceCount)x)"
        case .customInstruction:
            let snippet = (rule.preferredAction.value ?? "").prefix(32)
            return "\"\(trigger)\" -> custom: \(snippet)\(snippet.count == 32 ? "…" : "")"
        }
    }
}

@MainActor
final class AgentDecisionCenter: ObservableObject {
    @Published private(set) var currentDecision: AgentDecisionRequest?
    @Published private(set) var pendingCount: Int = 0

    private struct QueuedDecision {
        let request: AgentDecisionRequest
        let continuation: CheckedContinuation<AgentDecisionResolution, Never>
    }

    private struct ActiveDecision {
        let request: AgentDecisionRequest
        let continuation: CheckedContinuation<AgentDecisionResolution, Never>
        var timeoutTask: Task<Void, Never>?
    }

    private var queue: [QueuedDecision] = []
    private var active: ActiveDecision?
    private let preferenceStore: AgentPreferenceStore

    init(preferenceStore: AgentPreferenceStore) {
        self.preferenceStore = preferenceStore
    }

    deinit {
        active?.timeoutTask?.cancel()
    }

    func submit(_ request: AgentDecisionRequest) async -> AgentDecisionResolution {
        agentDecisionDebugLog("DecisionCenter.submit requestID=\(request.id.uuidString) kind=\(request.kind.rawValue) queueBefore=\(queue.count) active=\(currentDecision?.id.uuidString ?? "nil")")
        return await withCheckedContinuation { continuation in
            queue.append(QueuedDecision(request: request, continuation: continuation))
            refreshPendingCount()
            presentNextIfNeeded()
        }
    }

    func resolveCurrent(with result: AgentDecisionResult) {
        guard let active else { return }
        agentDecisionDebugLog("DecisionCenter.resolveCurrent requestID=\(active.request.id.uuidString) result=\(String(describing: result))")
        active.timeoutTask?.cancel()

        let resolution = makeResolution(request: active.request, result: result)
        let record = makeDecisionRecord(from: resolution)
        preferenceStore.recordDecision(record)

        self.active = nil
        currentDecision = nil
        refreshPendingCount()
        active.continuation.resume(returning: resolution)
        presentNextIfNeeded()
    }

    func dismissCurrent() {
        agentDecisionDebugLog("DecisionCenter.dismissCurrent activeRequestID=\(active?.request.id.uuidString ?? "nil")")
        resolveCurrent(with: .dismissed)
    }

    func clearHistory() {
        preferenceStore.clearDecisionHistory()
    }

    private func presentNextIfNeeded() {
        guard active == nil, !queue.isEmpty else { return }
        let next = queue.removeFirst()
        agentDecisionDebugLog("DecisionCenter.presentNext requestID=\(next.request.id.uuidString) queueRemaining=\(queue.count)")
        var timeoutTask: Task<Void, Never>?
        if let timeout = next.request.timeout, timeout > 0 {
            let requestID = next.request.id
            timeoutTask = Task { [weak self] in
                let nanos = UInt64(max(0, timeout) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
                await MainActor.run {
                    guard let self else { return }
                    guard self.active?.request.id == requestID else { return }
                    agentDecisionDebugLog("DecisionCenter.timeout requestID=\(requestID.uuidString)")
                    self.resolveCurrent(with: .timedOut)
                }
            }
        }
        active = ActiveDecision(request: next.request, continuation: next.continuation, timeoutTask: timeoutTask)
        currentDecision = next.request
        refreshPendingCount()
    }

    private func refreshPendingCount() {
        pendingCount = queue.count
    }

    private func makeResolution(
        request: AgentDecisionRequest,
        result: AgentDecisionResult
    ) -> AgentDecisionResolution {
        switch result {
        case .selected(let optionID):
            return AgentDecisionResolution(
                request: request,
                result: result,
                effectiveOutcome: .applyOption(optionID),
                wasDefaulted: false
            )
        case .otherwise(let text):
            return AgentDecisionResolution(
                request: request,
                result: result,
                effectiveOutcome: .otherwise(text),
                wasDefaulted: false
            )
        case .timedOut, .dismissed, .cancelled:
            let effective = effectiveOutcome(for: request.defaultPolicy)
            return AgentDecisionResolution(
                request: request,
                result: result,
                effectiveOutcome: effective,
                wasDefaulted: true
            )
        }
    }

    private func effectiveOutcome(for policy: AgentDecisionDefaultPolicy) -> AgentDecisionEffectiveOutcome {
        switch policy.kind {
        case .noOpContinue:
            return .noOpContinue
        case .applyOption:
            return .applyOption(policy.optionID ?? "")
        case .cancelOperation:
            return .cancelOperation
        }
    }

    private func makeDecisionRecord(from resolution: AgentDecisionResolution) -> AgentDecisionRecord {
        let resultKind: AgentDecisionRecordResultKind
        let selectedOptionID: String?
        let otherwiseText: String?

        switch resolution.result {
        case .selected(let optionID):
            resultKind = .selected
            selectedOptionID = optionID
            otherwiseText = nil
        case .otherwise(let text):
            resultKind = .otherwise
            selectedOptionID = nil
            otherwiseText = text
        case .timedOut:
            resultKind = .timedOut
            selectedOptionID = nil
            otherwiseText = nil
        case .dismissed:
            resultKind = .dismissed
            selectedOptionID = nil
            otherwiseText = nil
        case .cancelled:
            resultKind = .cancelled
            selectedOptionID = nil
            otherwiseText = nil
        }

        return AgentDecisionRecord(
            requestSnapshot: resolution.request,
            resultKind: resultKind,
            selectedOptionID: selectedOptionID,
            otherwiseText: otherwiseText,
            appliedActionSummary: summaryForResolution(resolution),
            wasDefaulted: resolution.wasDefaulted
        )
    }

    private func summaryForResolution(_ resolution: AgentDecisionResolution) -> String {
        switch resolution.effectiveOutcome {
        case .applyOption(let optionID):
            if let option = resolution.request.options.first(where: { $0.id == optionID }) {
                return option.title
            }
            return "Applied option \(optionID)"
        case .otherwise(let text):
            return "Otherwise: \(text)"
        case .noOpContinue:
            return "Defaulted to no-op continue"
        case .cancelOperation:
            return "Cancelled operation"
        }
    }
}

struct AgentEventClassificationAdvisor {
    enum Evaluation: Equatable {
        case skip(reason: String)
        case prompt(normalizedType: String)
    }

    @MainActor
    func evaluate(
        candidateTypeTitle: String,
        templateStore: EventTypeTemplateStore,
        preferenceStore: AgentPreferenceStore
    ) -> Evaluation {
        let trimmed = candidateTypeTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = EventTypeTemplateStore.normalizedTitle(trimmed)
        agentDecisionDebugLog("Advisor.evaluate candidate='\(trimmed)' normalized='\(normalized)'")

        guard !trimmed.isEmpty, !normalized.isEmpty else {
            agentDecisionDebugLog("Advisor.evaluate -> skip(empty type)")
            return .skip(reason: "empty type")
        }
        guard isValidHumanTypeTitle(trimmed) else {
            agentDecisionDebugLog("Advisor.evaluate -> skip(invalid type format)")
            return .skip(reason: "invalid type format")
        }
        guard !templateStore.contains(title: trimmed) else {
            agentDecisionDebugLog("Advisor.evaluate -> skip(template exists)")
            return .skip(reason: "template exists")
        }
        guard !preferenceStore.shouldSuppressMissingTypePrompt(for: normalized) else {
            agentDecisionDebugLog("Advisor.evaluate -> skip(suppressed by preference)")
            return .skip(reason: "suppressed by preference")
        }
        agentDecisionDebugLog("Advisor.evaluate -> prompt(normalizedType=\(normalized))")
        return .prompt(normalizedType: normalized)
    }

    private func isValidHumanTypeTitle(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...24).contains(trimmed.count) else { return false }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") { return false }

        let scalarCount = trimmed.unicodeScalars.count
        let letterLikeCount = trimmed.unicodeScalars.filter { scalar in
            CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar)
        }.count

        if letterLikeCount == 0 { return false }
        if scalarCount > 0 && Double(letterLikeCount) / Double(scalarCount) < 0.4 { return false }
        if trimmed.allSatisfy({ $0.isNumber }) { return false }
        return true
    }
}

struct AgentEventClassificationCommitter {
    func ensureTypeTemplate(
        title: String,
        templateStore: EventTypeTemplateStore
    ) -> EventTypeTemplateChangeResult {
        templateStore.ensureTemplate(title: title)
    }
}

@MainActor
final class AgentOperationCenter: ObservableObject {
    enum OptionID {
        static let createTemplate = "create_template"
        static let keepTypeOnly = "keep_type_only"
    }

    @Published private(set) var recentEvents: [AgentOperationEvent] = []
    @Published private(set) var latestEvent: AgentOperationEvent?

    private let decisionCenter: AgentDecisionCenter
    private let preferenceStore: AgentPreferenceStore
    private let templateStore: EventTypeTemplateStore
    private let advisor = AgentEventClassificationAdvisor()
    private let committer = AgentEventClassificationCommitter()
    private let askBeforeCreatingTypeTemplate: () -> Bool

    init(
        decisionCenter: AgentDecisionCenter,
        preferenceStore: AgentPreferenceStore,
        templateStore: EventTypeTemplateStore,
        askBeforeCreatingTypeTemplate: @escaping () -> Bool = {
            UserDefaults.standard.object(forKey: AppSettingsKeys.agentAskBeforeCreatingEventTypeTemplates) as? Bool ?? true
        }
    ) {
        self.decisionCenter = decisionCenter
        self.preferenceStore = preferenceStore
        self.templateStore = templateStore
        self.askBeforeCreatingTypeTemplate = askBeforeCreatingTypeTemplate
    }

    @discardableResult
    func maybeHandleMissingEventTypeTemplate(
        for eventID: UUID,
        isCalendarEvent: Bool,
        proposedType: String,
        store: EventStore,
        context: AgentDecisionContext
    ) async -> AgentClassificationOutcome {
        let trimmed = proposedType.trimmingCharacters(in: .whitespacesAndNewlines)
        let askBefore = askBeforeCreatingTypeTemplate()
        agentDecisionDebugLog("OperationCenter.maybeHandleMissingEventTypeTemplate start eventID=\(eventID.uuidString) isCalendar=\(isCalendarEvent) source=\(context.sourceScreen) proposedType='\(trimmed)' askBefore=\(askBefore)")
        guard !trimmed.isEmpty else { return .skipped(reason: "empty type") }

        let evaluation = advisor.evaluate(
            candidateTypeTitle: trimmed,
            templateStore: templateStore,
            preferenceStore: preferenceStore
        )
        switch evaluation {
        case .skip(let reason):
            agentDecisionDebugLog("OperationCenter -> skipped eventID=\(eventID.uuidString) reason=\(reason)")
            return .skipped(reason: reason)
        case .prompt(let normalizedType):
            if !askBefore {
                agentDecisionDebugLog("OperationCenter askBefore disabled; auto-attempt create template for '\(trimmed)'")
                let created = createTemplate(title: trimmed, eventID: eventID, operationID: context.operationID)
                return created ? .createdTemplate(title: trimmed) : .keptEventTypeOnly
            }

            recordOperationEvent(
                AgentOperationEvent(
                    operationID: context.operationID,
                    phase: .waitingDecision,
                    message: "Waiting for confirmation to create event type template \"\(trimmed)\"",
                    relatedEventID: eventID
                )
            )

            let prefersCreate = preferenceStore.prefersCreateTemplateRecommendation(for: normalizedType)
            let request = AgentDecisionRequest(
                kind: .missingEventTypeTemplate,
                title: "Create a new event type template?",
                message: "The agent used the type \"\(trimmed)\", but it is not in your event type templates yet.",
                options: [
                    AgentDecisionOption(
                        id: OptionID.createTemplate,
                        title: "Create \"\(trimmed)\" type template",
                        subtitle: "Future events can reuse this type with color/category support.",
                        effectPreview: nil,
                        isRecommended: prefersCreate || !preferenceStore.shouldSuppressMissingTypePrompt(for: normalizedType)
                    ),
                    AgentDecisionOption(
                        id: OptionID.keepTypeOnly,
                        title: "Keep event type only (don't create template)",
                        subtitle: "This event keeps the type text, but template list is unchanged.",
                        effectPreview: nil,
                        isRecommended: !prefersCreate
                    )
                ],
                recommendedOptionID: prefersCreate ? OptionID.createTemplate : OptionID.keepTypeOnly,
                otherwiseEnabled: true,
                defaultPolicy: .applyOption(OptionID.keepTypeOnly),
                timeout: 15,
                context: context
            )

            agentDecisionDebugLog("OperationCenter submitting decision request id=\(request.id.uuidString) eventID=\(eventID.uuidString) candidateType='\(trimmed)' normalized='\(normalizedType)'")
            let resolution = await decisionCenter.submit(request)
            agentDecisionDebugLog("OperationCenter received resolution requestID=\(request.id.uuidString) wasDefaulted=\(resolution.wasDefaulted)")
            return await handleClassificationDecisionResolution(
                resolution,
                candidateType: trimmed,
                eventID: eventID,
                isCalendarEvent: isCalendarEvent,
                store: store
            )
        }
    }

    func recordOperationEvent(_ event: AgentOperationEvent) {
        recentEvents.insert(event, at: 0)
        if recentEvents.count > 40 {
            recentEvents = Array(recentEvents.prefix(40))
        }
        latestEvent = event
    }

    private func handleClassificationDecisionResolution(
        _ resolution: AgentDecisionResolution,
        candidateType: String,
        eventID: UUID,
        isCalendarEvent: Bool,
        store: EventStore
    ) async -> AgentClassificationOutcome {
        agentDecisionDebugLog("OperationCenter.handleResolution eventID=\(eventID.uuidString) candidateType='\(candidateType)' effective=\(String(describing: resolution.effectiveOutcome)) defaulted=\(resolution.wasDefaulted)")
        switch resolution.effectiveOutcome {
        case .applyOption(let optionID):
            switch optionID {
            case OptionID.createTemplate:
                let created = createTemplate(
                    title: candidateType,
                    eventID: eventID,
                    operationID: resolution.request.context.operationID,
                    decisionID: resolution.request.id
                )
                return created ? .createdTemplate(title: candidateType) : .keptEventTypeOnly
            case OptionID.keepTypeOnly:
                let phase: AgentOperationPhase = resolution.wasDefaulted ? .defaulted : .succeeded
                recordOperationEvent(
                    AgentOperationEvent(
                        operationID: resolution.request.context.operationID,
                        phase: phase,
                        message: resolution.wasDefaulted
                            ? "No type template created for \"\(candidateType)\" (default applied)"
                            : "Kept event type \"\(candidateType)\" without creating a template",
                        timestamp: Date(),
                        relatedEventID: eventID,
                        decisionID: resolution.request.id
                    )
                )
                return resolution.wasDefaulted ? .defaultedNoTemplate : .keptEventTypeOnly
            default:
                return .keptEventTypeOnly
            }
        case .otherwise(let text):
            if let mapped = parseOtherwiseMappedType(from: text) {
                let updated = updateEventType(
                    eventID: eventID,
                    isCalendarEvent: isCalendarEvent,
                    to: mapped,
                    store: store
                )
                if updated {
                    recordOperationEvent(
                        AgentOperationEvent(
                            operationID: resolution.request.context.operationID,
                            phase: .succeeded,
                            message: "Updated event type to \"\(mapped)\" from custom instruction",
                            relatedEventID: eventID,
                            decisionID: resolution.request.id
                        )
                    )
                    return .updatedEventType(to: mapped)
                }
            }

            recordOperationEvent(
                AgentOperationEvent(
                    operationID: resolution.request.context.operationID,
                    phase: .succeeded,
                    message: "Recorded custom instruction for type \"\(candidateType)\" without creating a template",
                    relatedEventID: eventID,
                    decisionID: resolution.request.id
                )
            )
            return .keptEventTypeOnly
        case .noOpContinue:
            recordOperationEvent(
                AgentOperationEvent(
                    operationID: resolution.request.context.operationID,
                    phase: .defaulted,
                    message: "No template created for \"\(candidateType)\"",
                    relatedEventID: eventID,
                    decisionID: resolution.request.id
                )
            )
            return .defaultedNoTemplate
        case .cancelOperation:
            recordOperationEvent(
                AgentOperationEvent(
                    operationID: resolution.request.context.operationID,
                    phase: .failed,
                    message: "Classification operation cancelled",
                    relatedEventID: eventID,
                    decisionID: resolution.request.id
                )
            )
            return .failed(message: "cancelled")
        }
    }

    private func createTemplate(
        title: String,
        eventID: UUID,
        operationID: UUID,
        decisionID: UUID? = nil
    ) -> Bool {
        agentDecisionDebugLog("OperationCenter.createTemplate title='\(title)' eventID=\(eventID.uuidString) operationID=\(operationID.uuidString)")
        let result = committer.ensureTypeTemplate(title: title, templateStore: templateStore)
        switch result {
        case .created(let template):
            recordOperationEvent(
                AgentOperationEvent(
                    operationID: operationID,
                    phase: .succeeded,
                    message: "Created event type template \"\(template.title)\"",
                    relatedEventID: eventID,
                    decisionID: decisionID
                )
            )
            return true
        case .existing(let template):
            recordOperationEvent(
                AgentOperationEvent(
                    operationID: operationID,
                    phase: .succeeded,
                    message: "Type template \"\(template.title)\" already existed",
                    relatedEventID: eventID,
                    decisionID: decisionID
                )
            )
            return false
        case .invalid:
            recordOperationEvent(
                AgentOperationEvent(
                    operationID: operationID,
                    phase: .failed,
                    message: "Could not create a valid type template for \"\(title)\"",
                    relatedEventID: eventID,
                    decisionID: decisionID
                )
            )
            return false
        }
    }

    private func parseOtherwiseMappedType(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        for template in templateStore.templates {
            if trimmed.localizedCaseInsensitiveContains(template.title) {
                return template.title
            }
        }

        // Accept exact custom text if it already normalizes to a known template title.
        let normalized = EventTypeTemplateStore.normalizedTitle(trimmed)
        if let match = templateStore.templates.first(where: {
            EventTypeTemplateStore.normalizedTitle($0.title) == normalized
        }) {
            return match.title
        }
        return nil
    }

    private func updateEventType(
        eventID: UUID,
        isCalendarEvent: Bool,
        to newType: String,
        store: EventStore
    ) -> Bool {
        agentDecisionDebugLog("OperationCenter.updateEventType eventID=\(eventID.uuidString) isCalendar=\(isCalendarEvent) -> '\(newType)'")
        if isCalendarEvent {
            guard var event = store.findCalendarEvent(id: eventID) else { return false }
            event.type = newType
            store.updateCalendarEvent(EventLogTemplateAdvisor().applySuggestion(to: event))
            return true
        } else {
            guard var event = store.events.first(where: { $0.id == eventID }) else { return false }
            event.type = newType
            store.update(event)
            return true
        }
    }
}

@MainActor
final class AgentRuntime: ObservableObject {
    let eventTypeTemplateStore: EventTypeTemplateStore
    let preferenceStore: AgentPreferenceStore
    let decisionCenter: AgentDecisionCenter
    let operationCenter: AgentOperationCenter
    private var cancellables: Set<AnyCancellable> = []

    init() {
        let eventTypeTemplateStore = EventTypeTemplateStore()
        let preferenceStore = AgentPreferenceStore()
        self.eventTypeTemplateStore = eventTypeTemplateStore
        self.preferenceStore = preferenceStore
        self.decisionCenter = AgentDecisionCenter(preferenceStore: preferenceStore)
        self.operationCenter = AgentOperationCenter(
            decisionCenter: decisionCenter,
            preferenceStore: preferenceStore,
            templateStore: eventTypeTemplateStore
        )
        bindNestedObjectChanges()
    }

    init(
        eventTypeTemplateStore: EventTypeTemplateStore,
        preferenceStore: AgentPreferenceStore
    ) {
        self.eventTypeTemplateStore = eventTypeTemplateStore
        self.preferenceStore = preferenceStore
        self.decisionCenter = AgentDecisionCenter(preferenceStore: preferenceStore)
        self.operationCenter = AgentOperationCenter(
            decisionCenter: decisionCenter,
            preferenceStore: preferenceStore,
            templateStore: eventTypeTemplateStore
        )
        bindNestedObjectChanges()
    }

    private func bindNestedObjectChanges() {
        cancellables.removeAll()

        decisionCenter.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        operationCenter.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        preferenceStore.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }
}
