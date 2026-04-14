//
//  ChatMessage.swift
//  leanring-buddy
//
//  Model for a single message in the Clicky chat window.
//  Both voice (push-to-talk) and text (typed) exchanges share this model
//  so the chat window displays the full conversation history regardless of
//  how the user interacted with Clicky.
//
//  Codable so ChatHistoryStore can persist the message list to JSON.
//

import Foundation

/// Whether a chat message was authored by the user or Clicky.
enum ChatMessageRole: String, Codable {
    case user
    case assistant
}

/// How the message originated — pushed via voice or typed in the chat window.
/// Used by the chat UI to badge voice messages with a mic icon so the user
/// can see which exchanges came from push-to-talk vs typing.
enum ChatMessageSource: String, Codable {
    case voice
    case text
}

/// A single message in the Clicky chat window.
///
/// `content` is `var` because assistant messages are updated in-place during
/// streaming — each SSE chunk overwrites the accumulated text rather than
/// creating a new message.
///
/// `screenshotFileNames` is `var` because screenshots are compressed and saved
/// to disk asynchronously after the message is appended to the list. The field
/// starts empty and is filled in once the background save finishes.
struct ChatMessage: Identifiable, Codable {
    let id: UUID
    let role: ChatMessageRole
    var content: String
    let timestamp: Date
    let source: ChatMessageSource
    /// Screen text extracted via OCR/Accessibility at the time of the voice query.
    /// `nil` for text-chat messages and for Claude-mode voice messages where OCR
    /// is not run (Claude sees the actual screenshot instead).
    let ocrText: String?
    /// File names of compressed screenshots saved to disk for this message.
    /// Empty for text-chat messages and populated asynchronously for voice messages.
    /// Files live in `~/Library/Application Support/Clicky/screenshots/`.
    var screenshotFileNames: [String]

    /// Standard init — generates a new UUID automatically.
    init(
        role: ChatMessageRole,
        content: String,
        source: ChatMessageSource,
        ocrText: String? = nil,
        screenshotFileNames: [String] = []
    ) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.timestamp = Date()
        self.source = source
        self.ocrText = ocrText
        self.screenshotFileNames = screenshotFileNames
    }

    /// Init with an explicit UUID — used when the ID must be known before
    /// the struct is created (e.g. to name screenshot files after the message
    /// before appending it to the list).
    init(
        id: UUID,
        role: ChatMessageRole,
        content: String,
        source: ChatMessageSource,
        ocrText: String? = nil,
        screenshotFileNames: [String] = []
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = Date()
        self.source = source
        self.ocrText = ocrText
        self.screenshotFileNames = screenshotFileNames
    }
}
