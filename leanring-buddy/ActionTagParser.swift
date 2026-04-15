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
//    [MUSIC:action]               → media key control (play/pause/next/prev)
//    [CLICK:x,y:label:screenN]    → simulate a left mouse click at screenshot coords
//
//  All tags are stripped from the text before it is spoken or displayed.
//  Actions are executed silently in the background.
//

import CoreGraphics
import Foundation

// MARK: - Parsed actions

/// A [CLICK:x,y:label:screenN] tag extracted from a Claude response.
/// Coordinates are in the screenshot's pixel space (top-left origin),
/// matching the same coordinate system used by [POINT:] tags.
struct ParsedClickTarget {
    /// Pixel coordinate in the screenshot's coordinate space (top-left origin).
    let pixelCoordinate: CGPoint
    /// Short label describing what is being clicked (e.g. "render button"), or nil.
    let label: String?
    /// Which screen (1-based) the coordinate belongs to, or nil to default to
    /// the screen where the cursor currently sits.
    let screenNumber: Int?
}

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

    /// [MUSIC:action] media control commands (play, pause, toggle, next, prev).
    let musicActions: [String]

    /// [CLICK:x,y:label:screenN] targets to simulate left-clicks on.
    /// Coordinates are in the screenshot's pixel space, same as [POINT:] tags.
    let clickTargets: [ParsedClickTarget]

    var hasAnyActions: Bool {
        !logEntries.isEmpty || !openTargets.isEmpty || !shortcutNames.isEmpty
            || !reminders.isEmpty || !musicActions.isEmpty || !clickTargets.isEmpty
    }
}

// MARK: - Parser

enum ActionTagParser {

    // MARK: - Main entry point

    /// Parses all action tags from `responseText` (after NOTE tags have already been
    /// stripped), returns the cleaned text and all extracted actions.
    static func parse(from responseText: String) -> ParsedActionTags {
        var workingText = responseText

        let logEntries    = extractLogTags(from: workingText,      strippingFrom: &workingText)
        let openTargets   = extractOpenTags(from: workingText,     strippingFrom: &workingText)
        let shortcuts     = extractShortcutTags(from: workingText, strippingFrom: &workingText)
        let reminders     = extractRemindTags(from: workingText,   strippingFrom: &workingText)
        let musicActions  = extractMusicTags(from: workingText,    strippingFrom: &workingText)
        let clickTargets  = extractClickTags(from: workingText,    strippingFrom: &workingText)

        let cleanedText = workingText.trimmingCharacters(in: .whitespacesAndNewlines)

        return ParsedActionTags(
            cleanedText: cleanedText,
            logEntries: logEntries,
            openTargets: openTargets,
            shortcutNames: shortcuts,
            reminders: reminders,
            musicActions: musicActions,
            clickTargets: clickTargets
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

    // MARK: - [MUSIC:action]

    /// Matches: [MUSIC:play], [MUSIC:pause], [MUSIC:next], [MUSIC:prev], [MUSIC:toggle]
    private static func extractMusicTags(from text: String, strippingFrom working: inout String) -> [String] {
        let pattern = #"\[MUSIC:([^\]]+)\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        let nsRange = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: nsRange)

        var results: [String] = []
        for match in matches {
            guard let actionRange = Range(match.range(at: 1), in: text) else { continue }
            let action = String(text[actionRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !action.isEmpty { results.append(action) }
        }

        working = regex.stringByReplacingMatches(in: working, range: NSRange(working.startIndex..., in: working), withTemplate: "")
        return results
    }

    // MARK: - [CLICK:x,y:label:screenN]

    /// Matches: [CLICK:820,540:render button] or [CLICK:820,540:render button:screen2]
    /// Coordinate space matches [POINT:] — screenshot pixel coords, top-left origin.
    private static func extractClickTags(from text: String, strippingFrom working: inout String) -> [ParsedClickTarget] {
        // Capture groups: (1) x, (2) y, (3) optional label, (4) optional screen number
        let pattern = #"\[CLICK:(\d+)\s*,\s*(\d+)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        let nsRange = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: nsRange)

        var results: [ParsedClickTarget] = []
        for match in matches {
            guard let xRange = Range(match.range(at: 1), in: text),
                  let yRange = Range(match.range(at: 2), in: text),
                  let x = Double(text[xRange]),
                  let y = Double(text[yRange]) else { continue }

            var label: String? = nil
            if match.numberOfRanges >= 4, let labelRange = Range(match.range(at: 3), in: text) {
                let rawLabel = String(text[labelRange]).trimmingCharacters(in: .whitespaces)
                if !rawLabel.isEmpty { label = rawLabel }
            }

            var screenNumber: Int? = nil
            if match.numberOfRanges >= 5, let screenRange = Range(match.range(at: 4), in: text) {
                screenNumber = Int(text[screenRange])
            }

            results.append(ParsedClickTarget(
                pixelCoordinate: CGPoint(x: x, y: y),
                label: label,
                screenNumber: screenNumber
            ))
        }

        working = regex.stringByReplacingMatches(in: working, range: NSRange(working.startIndex..., in: working), withTemplate: "")
        return results
    }
}
