//
//  NotesStore.swift
//  leanring-buddy
//
//  Persists the user's local notes to disk across app launches. Mirrors the file
//  IO pattern of ConversationStore: a single Codable JSON file under
//  ~/Library/Application Support/Clicky/, ISO-8601 dates, atomic writes.
//
//  Layout inside ~/Library/Application Support/Clicky/:
//    notes.json     — [Note] array, newest-updated first
//
//  Unlike ConversationStore (which separates a file-backed store from the
//  CompanionManager view-model), NotesStore is itself an `@MainActor
//  ObservableObject` so the Notch Notes tab can own it as a `@StateObject` and
//  react to changes directly. There is no legacy format to migrate from.
//

import Combine
import Foundation

@MainActor
final class NotesStore: ObservableObject {

    /// All notes, kept sorted by most recently updated first. Published so the
    /// Notes tab re-renders on every create / update / delete.
    @Published private(set) var notes: [Note] = []

    // MARK: - File Layout

    private let notesFileURL: URL

    init() {
        let appSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!

        let clickyDirectoryURL = appSupportURL.appendingPathComponent("Clicky")
        notesFileURL = clickyDirectoryURL.appendingPathComponent("notes.json")

        try? FileManager.default.createDirectory(
            at: clickyDirectoryURL,
            withIntermediateDirectories: true
        )

        load()
    }

    // MARK: - Loading

    /// Loads notes from disk into memory, sorted newest-updated first. Safe to
    /// call again at any time — replaces the in-memory array.
    func load() {
        guard let jsonData = try? Data(contentsOf: notesFileURL) else {
            notes = []
            return
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard var decoded = try? decoder.decode([Note].self, from: jsonData) else {
            print("⚠️ NotesStore: Failed to decode notes.json — starting fresh")
            notes = []
            return
        }

        decoded.sort { $0.updatedAt > $1.updatedAt }
        notes = decoded
        print("🗒️ NotesStore: Loaded \(notes.count) note(s)")
    }

    // MARK: - Mutations

    /// Creates a new empty note, inserts it at the top, persists, and returns it
    /// so the caller can open it for editing immediately.
    @discardableResult
    func create() -> Note {
        let note = Note()
        notes.insert(note, at: 0)
        save()
        return note
    }

    /// Updates an existing note (matched by id), bumps its `updatedAt`, re-sorts,
    /// and persists. No-op if the note isn't found.
    func update(_ note: Note) {
        guard let index = notes.firstIndex(where: { $0.id == note.id }) else { return }
        var updated = note
        updated.updatedAt = Date()
        notes[index] = updated
        notes.sort { $0.updatedAt > $1.updatedAt }
        save()
    }

    /// Deletes the note with the given id and persists.
    func delete(id: UUID) {
        notes.removeAll { $0.id == id }
        save()
    }

    // MARK: - Saving

    /// Writes the current notes array to disk atomically.
    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted

        guard let jsonData = try? encoder.encode(notes) else {
            print("⚠️ NotesStore: Failed to encode notes")
            return
        }

        do {
            try jsonData.write(to: notesFileURL, options: .atomic)
        } catch {
            print("⚠️ NotesStore: Failed to write notes.json: \(error)")
        }
    }
}
