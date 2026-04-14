//
//  ActionTagParser.swift
//  leanring-buddy
//
//  Unified parser for all action tags embedded in Claude's responses.
//  Extends the existing [NOTE:] and [POINT:] pattern to cover learning
//  log entries, macOS actions (open URL/app, run Shortcut, set reminder).
//
//  Tag reference:
//    [NOTE:title]content[/NOTE]   → create Apple Note         (already in CompanionManager)
//    [LOG:app:topic]              → append to learning log     (new — Phase 1)
//    [OPEN:url-or-app-name]       → open URL or launch app     (new — Phase 2)
//    [SHORTCUT:name]              → run Apple Shortcut by name (new — Phase 2)
//    [REMIND:text:date-hint]      → create macOS reminder      (new — Phase 2)
//
//  All tags are stripped from the text before it is spoken or displayed.
//  Actions are executed silently in the background.
//

import Foundation

// MARK: - Parsed actions

/// All actions extracted from a single Claude response.
struct ParsedActionTags {
    /// The response text with every action tag stripped out, ready to speak or display.
    let cleanedText: String

    // NOTE tags are handled by the existing CompanionManager.parseAndStripNoteTags path
    // and are NOT duplicated here — this parser operates on text that has already had
    // NOTE tags removed.

    /// [LOG:app:topic] entries to append to the learning log.
    let logEntries: [(app: String, topic: String)]

    /// [OPEN:url-or-app] targets to open via NSWorkspace.
    let openTargets: [String]

    /// [SHORTCUT:name] shortcut names to run via the `shortcuts` CLI.
    let shortcutNames: [String]

    /// [REMIND:text:date-hint] reminders to create. dateHint is a human-readable
    /// string like "tomorrow 9am" — passed to the Shortcuts reminder action.
    let reminders: [(text: String, dateHint: String)]

    var hasAnyActions: Bool {
        !logEntries.isEmpty || !openTargets.isEmpty || !shortcutNames.isEmpty || !reminders.isEmpty
    }
}

// MARK: - Parser

enum ActionTagParser {

    // MARK: - Main entry point

    /// Parses all action tags from `responseText` (after NOTE tags have already been
    /// stripped), returns the cleaned text and all extracted actions.
    static func parse(from responseText: String) -> ParsedActionTags {
        var workingText = responseText

        let logEntries   = extractLogTags(from: workingText,   strippingFrom: &workingText)
        let openTargets  = extractOpenTags(from: workingText,  strippingFrom: &workingText)
        let shortcuts    = extractShortcutTags(from: workingText, strippingFrom: &workingText)
        let reminders    = extractRemindTags(from: workingText, strippingFrom: &workingText)

        let cleanedText = workingText.trimmingCharacters(in: .whitespacesAndNewlines)

        return ParsedActionTags(
            cleanedText: cleanedText,
            logEntries: logEntries,
            openTargets: openTargets,
            shortcutNames: shortcuts,
            reminders: reminders
        )
    }

    // MARK: - [LOG:app:topic]

    /// Matches: [LOG:DaVinci Resolve:color wheels]
    private static func extractLogTags(from text: String, strippingFrom working: inout String) -> [(app: String, topic: String)] {
        let pattern = #"\[LOG:([^\]:]+):([^\]]+)\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        let nsRange = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: nsRange)

        var results: [(app: String, topic: String)] = []
        for match in matches {
            guard let appRange   = Range(match.range(at: 1), in: text),
                  let topicRange = Range(match.range(at: 2), in: text) else { continue }
            let app   = String(text[appRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            let topic = String(text[topicRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !app.isEmpty && !topic.isEmpty {
                results.append((app: app, topic: topic))
            }
        }

        working = regex.stringByReplacingMatches(in: working, range: NSRange(working.startIndex..., in: working), withTemplate: "")
        return results
    }

    // MARK: - [OPEN:url-or-app]

    /// Matches: [OPEN:https://example.com] or [OPEN:Xcode]
    private static func extractOpenTags(from text: String, strippingFrom working: inout String) -> [String] {
        let pattern = #"\[OPEN:([^\]]+)\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        let nsRange = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: nsRange)

        var results: [String] = []
        for match in matches {
            guard let targetRange = Range(match.range(at: 1), in: text) else { continue }
            let target = String(text[targetRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !target.isEmpty { results.append(target) }
        }

        working = regex.stringByReplacingMatches(in: working, range: NSRange(working.startIndex..., in: working), withTemplate: "")
        return results
    }

    // MARK: - [SHORTCUT:name]

    /// Matches: [SHORTCUT:Morning Routine]
    private static func extractShortcutTags(from text: String, strippingFrom working: inout String) -> [String] {
        let pattern = #"\[SHORTCUT:([^\]]+)\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        let nsRange = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: nsRange)

        var results: [String] = []
        for match in matches {
            guard let nameRange = Range(match.range(at: 1), in: text) else { continue }
            let name = String(text[nameRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { results.append(name) }
        }

        working = regex.stringByReplacingMatches(in: working, range: NSRange(working.startIndex..., in: working), withTemplate: "")
        return results
    }

    // MARK: - [REMIND:text:date-hint]

    /// Matches: [REMIND:Practice Resolve audio:tomorrow 9am]
    private static func extractRemindTags(from text: String, strippingFrom working: inout String) -> [(text: String, dateHint: String)] {
        let pattern = #"\[REMIND:([^\]:]+):([^\]]+)\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        let nsRange = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: nsRange)

        var results: [(text: String, dateHint: String)] = []
        for match in matches {
            guard let textRange     = Range(match.range(at: 1), in: text),
                  let dateHintRange = Range(match.range(at: 2), in: text) else { continue }
            let reminderText = String(text[textRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            let dateHint     = String(text[dateHintRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !reminderText.isEmpty { results.append((text: reminderText, dateHint: dateHint)) }
        }

        working = regex.stringByReplacingMatches(in: working, range: NSRange(working.startIndex..., in: working), withTemplate: "")
        return results
    }
}
