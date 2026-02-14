//
//  ChatMessage.swift
//  Done
//

import Foundation

enum ChatMessageRole: String, Codable {
    case user
    case assistant
    case toolCall
    case toolResult
}

struct ChatMessage: Identifiable, Codable {
    var id: UUID
    var role: ChatMessageRole
    var content: String
    var timestamp: Date
    var toolName: String?
    var toolCallId: String?
    var isLoading: Bool

    init(
        id: UUID = UUID(),
        role: ChatMessageRole,
        content: String,
        timestamp: Date = Date(),
        toolName: String? = nil,
        toolCallId: String? = nil,
        isLoading: Bool = false
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.toolName = toolName
        self.toolCallId = toolCallId
        self.isLoading = isLoading
    }
}
