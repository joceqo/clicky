//
//  ChatMessage.swift
//  leanring-buddy
//
//  Model for a single message in the Clicky chat window.
//  Both voice (push-to-talk) and text (typed) exchanges share this model
//  so the chat window displays the full conversation history regardless of
//  how the user interacted with Clicky.
//

import Foundation

/// Whether a chat message was authored by the user or Clicky.
enum ChatMessageRole {
    case user
    case assistant
}

/// How the message originated — pushed via voice or typed in the chat window.
/// Used by the chat UI to badge voice messages with a mic icon so the user
/// can see which exchanges came from push-to-talk vs typing.
enum ChatMessageSource {
    case voice
    case text
}

/// A single message in the Clicky chat window.
/// `content` is `var` because assistant messages are updated in-place during
/// streaming — each SSE chunk appends to the same ChatMessage rather than
/// creating a new one.
struct ChatMessage: Identifiable {
    let id: UUID
    let role: ChatMessageRole
    var content: String
    let timestamp: Date
    let source: ChatMessageSource

    init(role: ChatMessageRole, content: String, source: ChatMessageSource) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.timestamp = Date()
        self.source = source
    }
}
