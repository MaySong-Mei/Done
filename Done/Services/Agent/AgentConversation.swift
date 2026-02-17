//
//  AgentConversation.swift
//  Done
//

import Foundation

struct AgentConversation: Identifiable, Codable {
    var id: UUID
    var title: String?
    var createdAt: Date
    var updatedAt: Date
    var messages: [ChatMessage]
    var involvedEventIDs: Set<UUID>
    var involvedEventNames: [UUID: String]

    var displayTitle: String {
        if let title, !title.isEmpty {
            return title
        }
        if let first = messages.first(where: { $0.role == .user }), !first.content.isEmpty {
            let snippet = first.content.prefix(40)
            return snippet.count < first.content.count ? "\(snippet)…" : String(snippet)
        }
        return "New Chat"
    }

    init(
        id: UUID = UUID(),
        title: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        messages: [ChatMessage] = [],
        involvedEventIDs: Set<UUID> = [],
        involvedEventNames: [UUID: String] = [:]
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
        self.involvedEventIDs = involvedEventIDs
        self.involvedEventNames = involvedEventNames
    }
}
