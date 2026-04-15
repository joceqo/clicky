//
//  Conversation.swift
//  leanring-buddy
//
//  Model for a single conversation in the Clicky chat window.
//  Each conversation has its own message history and metadata shown
//  in the sidebar. Codable so ConversationStore can persist the
//  conversations index to JSON.
//

import Foundation

struct Conversation: Identifiable, Codable {
    let id: UUID
    var title: String
    let createdAt: Date
    var updatedAt: Date
    var messageCount: Int

    /// Creates a new conversation with a default title.
    init(title: String = "New Chat") {
        self.id = UUID()
        self.title = title
        self.createdAt = Date()
        self.updatedAt = Date()
        self.messageCount = 0
    }

    /// Creates a conversation with explicit values — used during migration
    /// from the legacy single-history format.
    init(
        id: UUID,
        title: String,
        createdAt: Date,
        updatedAt: Date,
        messageCount: Int
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messageCount = messageCount
    }
}
