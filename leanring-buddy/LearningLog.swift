//
//  LearningLog.swift
//  leanring-buddy
//
//  A lightweight append-only log that records what the user has learned
//  during Clicky sessions. Each entry captures the app/context, topic,
//  date, and an optional link to the Apple Note that was created.
//
//  The log is stored as JSON at:
//    ~/Library/Application Support/Clicky/learning/log.json
//
//  It grows silently as the user converses with Clicky — they never
//  need to manage it directly. The Learning settings tab lets them
//  view, query, and delete entries.
//

import Foundation

// MARK: - Data model

/// A single learning event logged by Clicky.
struct LearningEntry: Codable, Identifiable {
    let id: UUID
    /// The app or broad context the user was working in (e.g. "DaVinci Resolve", "Xcode", "Swift").
    let app: String
    /// The specific concept or topic covered (e.g. "color wheels", "closures").
    let topic: String
    /// When the entry was recorded.
    let date: Date
    /// Title of the Apple Note created alongside this entry, if any.
    let noteTitle: String?

    init(app: String, topic: String, date: Date = Date(), noteTitle: String? = nil) {
        self.id = UUID()
        self.app = app
        self.topic = topic
        self.date = date
        self.noteTitle = noteTitle
    }
}

// MARK: - Store

/// Manages the on-disk learning log. Loads on first access and writes
/// atomically after every append so the log is never left in a corrupt state.
final class LearningLogStore {

    // MARK: - File location

    private let logFileURL: URL

    init() {
        let appSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let learningDirectoryURL = appSupportURL
            .appendingPathComponent("Clicky")
            .appendingPathComponent("learning")
        logFileURL = learningDirectoryURL.appendingPathComponent("log.json")

        // Create the directory if it doesn't exist yet
        try? FileManager.default.createDirectory(
            at: learningDirectoryURL,
            withIntermediateDirectories: true
        )
    }

    // MARK: - Read

    /// Loads and returns all entries from disk, oldest first.
    func loadAllEntries() -> [LearningEntry] {
        guard let data = try? Data(contentsOf: logFileURL),
              let entries = try? JSONDecoder().decode([LearningEntry].self, from: data)
        else { return [] }
        return entries.sorted { $0.date < $1.date }
    }

    /// Returns entries logged within the last `days` calendar days.
    func loadRecentEntries(withinDays days: Int) -> [LearningEntry] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        return loadAllEntries().filter { $0.date >= cutoff }
    }

    /// Returns all entries for a specific app, case-insensitive.
    func loadEntries(forApp appName: String) -> [LearningEntry] {
        let lowercased = appName.lowercased()
        return loadAllEntries().filter { $0.app.lowercased().contains(lowercased) }
    }

    /// Returns all unique app names in the log, sorted alphabetically.
    func allApps() -> [String] {
        let apps = Set(loadAllEntries().map { $0.app })
        return apps.sorted()
    }

    // MARK: - Write

    /// Appends a new entry to the log and writes the updated array to disk atomically.
    func append(_ entry: LearningEntry) {
        var entries = loadAllEntries()
        entries.append(entry)
        saveEntries(entries)
        print("📚 Learning log: appended \"\(entry.topic)\" in \"\(entry.app)\"")
    }

    /// Deletes a single entry by ID and persists the updated log.
    func deleteEntry(withID entryID: UUID) {
        var entries = loadAllEntries()
        entries.removeAll { $0.id == entryID }
        saveEntries(entries)
    }

    /// Deletes all entries. Used from the Learning settings tab.
    func clearAllEntries() {
        saveEntries([])
    }

    // MARK: - Private

    private func saveEntries(_ entries: [LearningEntry]) {
        guard let data = try? JSONEncoder().encode(entries) else {
            print("⚠️ LearningLogStore: failed to encode entries")
            return
        }
        // Write atomically to avoid corruption if the app quits mid-write
        try? data.write(to: logFileURL, options: .atomic)
    }

    // MARK: - Summary helpers (used by quiz + "what did I learn" queries)

    /// Builds a plain-text summary of recent entries suitable for
    /// injecting into Claude's context when the user asks "what did I learn?"
    /// or "quiz me on X". Capped at `maxEntries` to keep the context small.
    func buildContextSummary(forApp appFilter: String? = nil, withinDays days: Int = 30, maxEntries: Int = 20) -> String {
        let entries: [LearningEntry]
        if let appFilter {
            entries = loadEntries(forApp: appFilter).suffix(maxEntries).array
        } else {
            entries = loadRecentEntries(withinDays: days).suffix(maxEntries).array
        }

        guard !entries.isEmpty else {
            return "No learning entries found\(appFilter.map { " for \($0)" } ?? "")."
        }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none

        let lines = entries.map { entry in
            "- \(formatter.string(from: entry.date)): [\(entry.app)] \(entry.topic)"
        }

        return "Learning log:\n" + lines.joined(separator: "\n")
    }

    // MARK: - Markdown export

    /// Exports the full learning log as a Markdown string, grouped by app
    /// and sorted alphabetically. Suitable for dropping into an Obsidian
    /// vault, Notion import, or any Markdown-aware notes app.
    func exportAsMarkdown() -> String {
        let allEntries = loadAllEntries()
        guard !allEntries.isEmpty else {
            return "# Clicky Learning Log\n\n*No entries yet.*\n"
        }

        let entryDateFormatter = DateFormatter()
        entryDateFormatter.dateStyle = .medium
        entryDateFormatter.timeStyle = .none

        let exportDateFormatter = DateFormatter()
        exportDateFormatter.dateStyle = .long
        exportDateFormatter.timeStyle = .none

        var lines: [String] = [
            "# Clicky Learning Log",
            "",
            "*Exported \(exportDateFormatter.string(from: Date()))*",
            "",
        ]

        // Group by app, sort apps alphabetically, entries within each app by date
        let grouped = Dictionary(grouping: allEntries) { $0.app }
        for app in grouped.keys.sorted() {
            let sortedEntries = (grouped[app] ?? []).sorted { $0.date < $1.date }
            lines.append("## \(app)")
            lines.append("")
            for entry in sortedEntries {
                var entryLine = "- **\(entry.topic)** — \(entryDateFormatter.string(from: entry.date))"
                if let noteTitle = entry.noteTitle {
                    entryLine += " *(Note: \(noteTitle))*"
                }
                lines.append(entryLine)
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }
}

// MARK: - Collection helper

private extension Collection {
    /// Converts a `SubSequence` (from `suffix`) back to an Array.
    var array: [Element] { Array(self) }
}
