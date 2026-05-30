//
//  Note.swift
//  leanring-buddy
//
//  Model for a single local note shown in the Notch "Notes" tab. Mirrors the
//  commercial Clicky "Notes"/WikiArticle shape (title + body + timestamps).
//  Codable so NotesStore can persist the notes array to JSON in Application
//  Support — the same pattern Conversation/ConversationStore use.
//

import Foundation

struct Note: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var body: String
    let createdAt: Date
    var updatedAt: Date

    /// Creates a new, empty note with default values.
    init(title: String = "", body: String = "") {
        self.id = UUID()
        self.title = title
        self.body = body
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    /// Creates a note with explicit values — used when decoding from disk.
    init(id: UUID, title: String, body: String, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.title = title
        self.body = body
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// A display title that falls back to a placeholder when the note is untitled.
    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled note" : trimmed
    }
}
