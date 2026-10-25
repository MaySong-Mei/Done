//
//  AgentConversation.swift
//  Done
//

import Foundation

/// `Equatable` so a cache can ask "did the owner actually move?" — see
/// `AgentService.adoptRepositoryState`. Comparing ids alone would miss an
/// edited transcript; re-encoding to compare bytes would run the encoder on
/// every commit notification.
struct AgentConversation: Identifiable, Codable, Equatable {
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

    /// Hand-written so the bytes are a function of the VALUE, not of the
    /// process. A `Set` and a non-String-keyed `Dictionary` encode in hash
    /// order, which is reseeded every launch, and `.sortedKeys` only orders
    /// object keys — so the synthesized encoder gave this row a new hash on
    /// every launch and `syncAgentConversations` re-uploaded the whole history
    /// each time (gh#257). The wire shape is exactly the synthesized one: the
    /// set is a JSON array, the map is the flat `[key, value, key, value]`
    /// array Swift uses for `UUID` keys — only the order is now fixed (by
    /// `uuidString`). Decoding stays synthesized, so rows written in the old
    /// order still decode. See `AgentConversationEncodingTests`.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(messages, forKey: .messages)
        try container.encode(Self.orderedIDs(involvedEventIDs), forKey: .involvedEventIDs)
        var names = container.nestedUnkeyedContainer(forKey: .involvedEventNames)
        for id in Self.orderedIDs(involvedEventNames.keys) {
            try names.encode(id)
            try names.encode(involvedEventNames[id]!)
        }
    }

    /// The one ordering both collections encode in.
    static func orderedIDs<C: Collection>(_ ids: C) -> [UUID] where C.Element == UUID {
        ids.sorted { $0.uuidString < $1.uuidString }
    }
}
