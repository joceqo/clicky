//
//  ReadAloudSessionLog.swift
//  leanring-buddy
//
//  Persistent session-level log for the ⌃⇧L read-aloud pipeline.
//
//  Every press writes exactly one JSONL record describing that session:
//  which app was frontmost, which extraction strategy won, how long each
//  phase took, whether the user stopped playback, and whether the pipeline
//  errored. The log lives at:
//
//      ~/Library/Application Support/Clicky/logs/read-aloud.jsonl
//
//  Unlike the OSLog / signpost streams (which macOS garbage-collects within
//  hours), this file sticks around until it is manually cleared or rotated.
//  The goal is to come back days later, read the log, and spot patterns in
//  what worked and what didn't — for example "Chrome always falls back to
//  OCR", "VS Code AX times out", "cursor-crop returned empty on Figma".
//
//  Rotation: on first use in a new session, any log file older than seven
//  days is renamed to `read-aloud.jsonl.archive-YYYYMMDD` so the live file
//  stays focused on recent activity. The last four archives are kept.
//

import Foundation

/// Which strategy produced the extracted text for a read-aloud session. One
/// of these is always set on a completed record; the pre-failure records use
/// `.unknown` when extraction itself blew up before succeeding.
enum ReadAloudSessionExtractionSource: String, Codable {
    case accessibility
    case ocr
    case cursorCropOCR
    case unknown
}

/// How the session ended. Recorded as a string so new cases can be added
/// later without breaking historical records that already landed on disk.
enum ReadAloudSessionOutcome: String, Codable {
    case played
    case stoppedByUser
    case error
}

/// One line in `read-aloud.jsonl`. Captures the session's trigger context,
/// the phase timings we care about for perf work, and an outcome so I can
/// later grep for "what went wrong on Chrome last Tuesday".
///
/// All optional fields are `nil` when the session ended before that phase
/// ran (e.g. an error during text extraction leaves synthesis fields blank).
struct ReadAloudSessionRecord: Codable {
    let schemaVersion: Int
    let sessionID: String
    let triggeredAt: Date

    // Context
    let foregroundAppBundleID: String?
    let foregroundAppName: String?
    let foregroundWindowTitle: String?
    let popoverDisplayMode: String
    let highlightStyle: String
    let readMode: String

    // Extraction phase
    let extractionSource: ReadAloudSessionExtractionSource
    let extractedWordCount: Int?
    let extractedWordsWithBounds: Int?
    let extractionDurationSeconds: Double?
    let skippedAccessibilityCache: Bool
    let cursorCropAttempted: Bool
    let cursorCropProducedText: Bool?

    // Synthesis phase
    let charactersSynthesized: Int?
    let wordsSpoken: Int?
    let synthesisDurationSeconds: Double?
    let audioDurationSeconds: Double?

    // End-to-end
    let endToEndLatencySeconds: Double?

    // Quality signals — what the log can't answer with perf alone:
    // "did the highlight track?" "was this even prose?" "what language?"
    /// Characters in the text that was actually sent to the synthesizer.
    let characterCount: Int?
    /// Fraction (0–1) of spoken words whose stored screenBounds came back
    /// non-zero. Low values mean the highlight overlay was floating in empty
    /// space for most of the session — a visible regression indicator.
    let highlightCoverageFraction: Double?
    /// Heuristic flag: true when the read text looks like source code
    /// (symbol density + common code tokens). Useful for filtering
    /// "read-aloud triggered on a code block" noise when evaluating quality.
    let textLooksLikeCode: Bool?
    /// ISO-639 language code detected from the text (e.g. "en", "fr").
    let detectedLanguageCode: String?
    /// Short excerpt (first ~120 chars) of what was actually spoken. Stored
    /// so I can tell from the log *what* got read without having to replay.
    let spokenTextExcerpt: String?

    // Outcome
    let outcome: ReadAloudSessionOutcome
    let errorDomain: String?
    let errorCode: Int?
    let errorDescription: String?
}

/// Builder for a `ReadAloudSessionRecord`. Holds the partial state as the
/// pipeline advances through its phases; at each exit (success / cancel /
/// error) the owning Task calls `build(...)` to seal the values and the
/// store writes the resulting line to disk.
///
/// This builder is intentionally a plain struct (not an actor) — it only
/// ever lives on the pipeline's main-actor Task, and values are captured
/// into the record before hitting the background writer.
struct ReadAloudSessionLogBuilder {
    let schemaVersion: Int = 2
    let sessionID: String
    let triggeredAt: Date

    var foregroundAppBundleID: String?
    var foregroundAppName: String?
    var foregroundWindowTitle: String?
    var popoverDisplayMode: String
    var highlightStyle: String
    var readMode: String

    var extractionSource: ReadAloudSessionExtractionSource = .unknown
    var extractedWordCount: Int?
    var extractedWordsWithBounds: Int?
    var extractionDurationSeconds: Double?
    var skippedAccessibilityCache: Bool = false
    var cursorCropAttempted: Bool = false
    var cursorCropProducedText: Bool?

    var charactersSynthesized: Int?
    var wordsSpoken: Int?
    var synthesisDurationSeconds: Double?
    var audioDurationSeconds: Double?

    var endToEndLatencySeconds: Double?

    var characterCount: Int?
    var highlightCoverageFraction: Double?
    var textLooksLikeCode: Bool?
    var detectedLanguageCode: String?
    var spokenTextExcerpt: String?

    /// Seals the builder into a concrete record with the outcome decided by
    /// the exit site (success / user stop / error).
    func build(outcome: ReadAloudSessionOutcome, error: Error? = nil) -> ReadAloudSessionRecord {
        let nsError = error as NSError?
        return ReadAloudSessionRecord(
            schemaVersion: schemaVersion,
            sessionID: sessionID,
            triggeredAt: triggeredAt,
            foregroundAppBundleID: foregroundAppBundleID,
            foregroundAppName: foregroundAppName,
            foregroundWindowTitle: foregroundWindowTitle,
            popoverDisplayMode: popoverDisplayMode,
            highlightStyle: highlightStyle,
            readMode: readMode,
            extractionSource: extractionSource,
            extractedWordCount: extractedWordCount,
            extractedWordsWithBounds: extractedWordsWithBounds,
            extractionDurationSeconds: extractionDurationSeconds,
            skippedAccessibilityCache: skippedAccessibilityCache,
            cursorCropAttempted: cursorCropAttempted,
            cursorCropProducedText: cursorCropProducedText,
            charactersSynthesized: charactersSynthesized,
            wordsSpoken: wordsSpoken,
            synthesisDurationSeconds: synthesisDurationSeconds,
            audioDurationSeconds: audioDurationSeconds,
            endToEndLatencySeconds: endToEndLatencySeconds,
            characterCount: characterCount,
            highlightCoverageFraction: highlightCoverageFraction,
            textLooksLikeCode: textLooksLikeCode,
            detectedLanguageCode: detectedLanguageCode,
            spokenTextExcerpt: spokenTextExcerpt,
            outcome: outcome,
            errorDomain: nsError?.domain,
            errorCode: nsError?.code,
            errorDescription: error.map { String(describing: $0) }
        )
    }
}

// MARK: - Quality heuristics

enum ReadAloudSessionQualityHeuristics {
    /// Best-effort detector for "this looks like source code rather than
    /// prose". Flags true when enough of these co-occur: heavy
    /// punctuation/symbol density, bracket/paren density, multiple common
    /// code tokens (`func`, `return`, `import`, `class`, etc.). Cheap — runs
    /// in O(n) over the candidate text.
    static func textLooksLikeCode(_ text: String) -> Bool {
        guard text.count >= 40 else { return false }
        let codeTokens: Set<String> = [
            "func", "return", "import", "class", "struct", "let", "var",
            "const", "function", "def", "null", "void", "public", "private",
            "=>", "->", "===", "!==", "::"
        ]
        let lowercasedText = text.lowercased()
        var matchedTokenCount = 0
        for token in codeTokens where lowercasedText.contains(token) {
            matchedTokenCount += 1
            if matchedTokenCount >= 2 { break }
        }

        var bracketOrBraceOrParenCount = 0
        var semicolonCount = 0
        var assignmentLikeSymbolCount = 0
        for scalar in text.unicodeScalars {
            switch scalar {
            case "{", "}", "(", ")", "[", "]":
                bracketOrBraceOrParenCount += 1
            case ";":
                semicolonCount += 1
            case "=":
                assignmentLikeSymbolCount += 1
            default:
                break
            }
        }

        let length = Double(text.count)
        let bracketDensity = Double(bracketOrBraceOrParenCount) / length
        let hasHighBracketDensity = bracketDensity > 0.03
        let hasLotsOfSemicolons = semicolonCount >= 3
        let hasLotsOfEquals = assignmentLikeSymbolCount >= 3

        let signalsTriggered = [
            matchedTokenCount >= 2,
            hasHighBracketDensity,
            hasLotsOfSemicolons,
            hasLotsOfEquals
        ].filter { $0 }.count
        return signalsTriggered >= 2
    }

    /// Computes the fraction of spoken words whose screen bounds came back
    /// non-zero. Returned value is in `[0, 1]`, or `nil` if there's nothing
    /// to divide by (zero spoken words — the session errored before audio).
    static func highlightCoverageFraction(
        spokenWordCount: Int,
        spokenWordsWithBoundsCount: Int
    ) -> Double? {
        guard spokenWordCount > 0 else { return nil }
        return Double(spokenWordsWithBoundsCount) / Double(spokenWordCount)
    }

    /// Returns a short single-line preview of `text` — the first `limit`
    /// characters flattened to a single line — for the JSONL log. Kept small
    /// on purpose so the log stays compact and the file grep-able.
    static func spokenTextExcerpt(_ text: String, limit: Int = 120) -> String {
        let singleLine = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        if singleLine.count <= limit { return singleLine }
        let endIndex = singleLine.index(singleLine.startIndex, offsetBy: limit)
        return String(singleLine[..<endIndex]) + "…"
    }
}

/// Thread-safe appender for `read-aloud.jsonl`. One instance per app.
/// Appending is fire-and-forget from the caller's perspective: the store
/// hops to a background queue for all disk IO so the read-aloud pipeline
/// never blocks on a log write.
final class ReadAloudSessionLogStore {
    private let logsDirectoryURL: URL
    private let logFileURL: URL
    private let writeQueue = DispatchQueue(label: "com.clicky.read-aloud-session-log", qos: .utility)
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // One line per record — no pretty printing so the file stays
        // grep-able and each entry fits a single log line.
        encoder.outputFormatting = []
        return encoder
    }()

    init() {
        let appSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        logsDirectoryURL = appSupportURL
            .appendingPathComponent("Clicky")
            .appendingPathComponent("logs")
        logFileURL = logsDirectoryURL.appendingPathComponent("read-aloud.jsonl")

        try? FileManager.default.createDirectory(
            at: logsDirectoryURL,
            withIntermediateDirectories: true
        )
        rotateIfOlderThanSevenDays()
    }

    /// Appends a single record to the JSONL file on the background writer
    /// queue. Safe to call from any thread; returns immediately.
    func append(_ record: ReadAloudSessionRecord) {
        let encoder = self.encoder
        let logFileURL = self.logFileURL
        writeQueue.async {
            guard let encodedRecordData = try? encoder.encode(record) else {
                return
            }
            // One record per line — write the JSON bytes followed by a newline.
            var lineData = encodedRecordData
            lineData.append(0x0A)

            if !FileManager.default.fileExists(atPath: logFileURL.path) {
                try? lineData.write(to: logFileURL, options: .atomic)
                return
            }

            if let fileHandle = try? FileHandle(forWritingTo: logFileURL) {
                defer { try? fileHandle.close() }
                try? fileHandle.seekToEnd()
                try? fileHandle.write(contentsOf: lineData)
            }
        }
    }

    /// If the live log file is older than seven days, rename it to an
    /// archive and let the next write start a fresh file. Keeps only the
    /// last four archives so the logs directory doesn't grow unbounded.
    private func rotateIfOlderThanSevenDays() {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: logFileURL.path),
              let modificationDate = attributes[.modificationDate] as? Date else {
            return
        }
        let sevenDaysInSeconds: TimeInterval = 7 * 24 * 60 * 60
        guard Date().timeIntervalSince(modificationDate) > sevenDaysInSeconds else { return }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        let archiveSuffix = formatter.string(from: modificationDate)
        let archiveURL = logsDirectoryURL.appendingPathComponent(
            "read-aloud.jsonl.archive-\(archiveSuffix)"
        )
        try? FileManager.default.moveItem(at: logFileURL, to: archiveURL)

        pruneOldArchivesKeepingLatest(count: 4)
    }

    private func pruneOldArchivesKeepingLatest(count keepCount: Int) {
        guard let archiveURLs = try? FileManager.default.contentsOfDirectory(
            at: logsDirectoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let archivedLogFiles = archiveURLs.filter {
            $0.lastPathComponent.hasPrefix("read-aloud.jsonl.archive-")
        }
        guard archivedLogFiles.count > keepCount else { return }

        let archivedLogFilesSortedOldestFirst = archivedLogFiles.sorted {
            let lhsModDate = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
            let rhsModDate = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
            return lhsModDate < rhsModDate
        }
        let filesToRemoveCount = archivedLogFilesSortedOldestFirst.count - keepCount
        for archivedLogFileURL in archivedLogFilesSortedOldestFirst.prefix(filesToRemoveCount) {
            try? FileManager.default.removeItem(at: archivedLogFileURL)
        }
    }
}
