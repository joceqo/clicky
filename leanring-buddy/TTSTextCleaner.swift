//
//  TTSTextCleaner.swift
//  leanring-buddy
//
//  Strips markdown, code blocks, HTML, and other visual-only syntax so the
//  text that reaches ElevenLabs/Supertonic reads cleanly aloud. Used for
//  every chat response before TTS synthesis.
//

import Foundation

enum TTSTextCleaner {

    /// Cleans `rawText` for speech synthesis. Removes markdown syntax,
    /// code blocks, HTML tags, and other visual-only artifacts that would
    /// sound wrong when spoken aloud (e.g. "asterisk asterisk bold").
    ///
    /// The goal is readable prose, not a lossless round-trip — code fences
    /// are dropped entirely because reading source code aloud is never
    /// useful in practice.
    static func cleanForSpeech(_ rawText: String) -> String {
        var text = rawText

        // Strip legacy V1R4 `<tts>` blocks wrapped in HTML comments, plus
        // any stray HTML comments. Comments come first so a tag inside a
        // comment doesn't get promoted by the tag stripper.
        text = removeHTMLComments(text)
        text = removeFencedCodeBlocks(text)
        text = removeImageLinks(text)
        text = replaceHyperlinks(text)
        text = removeHTMLTags(text)
        text = cleanLineByLine(text)
        text = removeInlineCodeBackticks(text)
        text = removeEmphasisMarkers(text)
        text = collapseWhitespace(text)

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Individual passes

    private static func removeHTMLComments(_ input: String) -> String {
        // Matches `<!-- ... -->` non-greedily, including across newlines.
        return input.replacingOccurrences(
            of: "<!--[\\s\\S]*?-->",
            with: "",
            options: .regularExpression
        )
    }

    private static func removeFencedCodeBlocks(_ input: String) -> String {
        // Matches triple-backtick fenced blocks, optional language tag, any
        // content across newlines, closing fence. Non-greedy so two blocks
        // in a row don't get merged.
        return input.replacingOccurrences(
            of: "```[\\s\\S]*?```",
            with: " ",
            options: .regularExpression
        )
    }

    private static func removeImageLinks(_ input: String) -> String {
        // `![alt](url)` — drop entirely. The alt text is usually redundant
        // or purely decorative.
        return input.replacingOccurrences(
            of: "!\\[[^\\]]*\\]\\([^)]*\\)",
            with: "",
            options: .regularExpression
        )
    }

    private static func replaceHyperlinks(_ input: String) -> String {
        // `[label](url)` → `label`. Keeps the human-readable label, drops
        // the URL which would otherwise be read character-by-character.
        return input.replacingOccurrences(
            of: "\\[([^\\]]+)\\]\\([^)]*\\)",
            with: "$1",
            options: .regularExpression
        )
    }

    private static func removeHTMLTags(_ input: String) -> String {
        // Any remaining `<tag>` or `</tag>` including attributes. Runs after
        // comment removal so tags inside comments aren't double-processed.
        return input.replacingOccurrences(
            of: "<[^>]+>",
            with: "",
            options: .regularExpression
        )
    }

    /// Per-line cleanup for syntax that only makes sense at line start:
    /// headings, list markers, blockquotes, horizontal rules, table rows.
    private static func cleanLineByLine(_ input: String) -> String {
        let lines = input.components(separatedBy: "\n")
        var cleaned: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Horizontal rules: `---`, `***`, `___`, optionally repeated.
            if trimmed.range(of: "^(-{3,}|\\*{3,}|_{3,})$", options: .regularExpression) != nil {
                continue
            }

            // Table separator row: `|---|---|` or `| :---: | ---: |`.
            if trimmed.range(of: "^\\|?\\s*:?-{3,}:?(\\s*\\|\\s*:?-{3,}:?)+\\s*\\|?$", options: .regularExpression) != nil {
                continue
            }

            // Table body row: starts and ends with `|`. We skip instead of
            // trying to linearize — spoken tables are almost always noise.
            if trimmed.hasPrefix("|") && trimmed.hasSuffix("|") && trimmed.count > 1 {
                continue
            }

            var processedLine = line

            // Heading marker `#`, `##`, ... up to 6 — strip the `#`s and the
            // single space that follows them.
            processedLine = processedLine.replacingOccurrences(
                of: "^(\\s*)#{1,6}\\s+",
                with: "$1",
                options: .regularExpression
            )

            // Blockquote marker `>` at line start (possibly indented).
            processedLine = processedLine.replacingOccurrences(
                of: "^(\\s*)>+\\s?",
                with: "$1",
                options: .regularExpression
            )

            // Unordered list markers `-`, `*`, `+` at line start.
            processedLine = processedLine.replacingOccurrences(
                of: "^(\\s*)[-*+]\\s+",
                with: "$1",
                options: .regularExpression
            )

            // Ordered list markers `1.`, `42.` at line start.
            processedLine = processedLine.replacingOccurrences(
                of: "^(\\s*)\\d+\\.\\s+",
                with: "$1",
                options: .regularExpression
            )

            cleaned.append(processedLine)
        }
        return cleaned.joined(separator: "\n")
    }

    private static func removeInlineCodeBackticks(_ input: String) -> String {
        // `code` → code. Keep the content, drop the backticks. A full strip
        // would break sentences like "the `foo` flag does X".
        return input.replacingOccurrences(
            of: "`([^`]+)`",
            with: "$1",
            options: .regularExpression
        )
    }

    private static func removeEmphasisMarkers(_ input: String) -> String {
        var text = input
        // Bold: `**text**` or `__text__` → text. Run before single-marker
        // emphasis so the double markers don't leak through as singles.
        text = text.replacingOccurrences(
            of: "\\*\\*([^*]+)\\*\\*",
            with: "$1",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: "__([^_]+)__",
            with: "$1",
            options: .regularExpression
        )
        // Italic: `*text*` or `_text_` → text.
        text = text.replacingOccurrences(
            of: "\\*([^*\\n]+)\\*",
            with: "$1",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: "(?<![a-zA-Z0-9])_([^_\\n]+)_(?![a-zA-Z0-9])",
            with: "$1",
            options: .regularExpression
        )
        // Strikethrough: `~~text~~` → text.
        text = text.replacingOccurrences(
            of: "~~([^~]+)~~",
            with: "$1",
            options: .regularExpression
        )
        return text
    }

    private static func collapseWhitespace(_ input: String) -> String {
        var text = input
        // Three or more newlines → two (paragraph break).
        text = text.replacingOccurrences(
            of: "\\n{3,}",
            with: "\n\n",
            options: .regularExpression
        )
        // Runs of spaces/tabs on a single line → one space.
        text = text.replacingOccurrences(
            of: "[ \\t]{2,}",
            with: " ",
            options: .regularExpression
        )
        return text
    }
}
