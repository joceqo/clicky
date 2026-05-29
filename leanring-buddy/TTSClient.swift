//
//  TTSClient.swift
//  leanring-buddy
//
//  Protocol for pluggable text-to-speech backends.
//  Conforming types speak text aloud and signal completion so callers
//  can drive phrase-by-phrase playback and track which sentence is live.
//

import Foundation
import NaturalLanguage

/// A pluggable text-to-speech backend.
protocol TTSClient: AnyObject {

    /// Whether audio is currently playing.
    var isPlaying: Bool { get }

    /// Stops any in-progress playback immediately.
    func stopPlayback()

    /// Speaks `text` and awaits completion of the full audio playback before returning.
    /// Throws on network or audio errors. Safe to cancel — cancellation stops playback
    /// and throws `CancellationError`.
    func speakText(_ text: String) async throws
}

// MARK: - Sentence Splitter

/// Splits TTS response text into sentence-level chunks suitable for
/// sequential phrase-by-phrase playback. Used by CompanionManager to
/// drive TTS one phrase at a time and track which phrase is currently playing.
enum TTSSentenceSplitter {

    /// Splits `text` into an array of complete sentences using NLTokenizer
    /// for linguistically-aware boundary detection (handles abbreviations,
    /// ellipses, and other edge cases that naive period-splitting misses).
    /// If the input produces no sentences (e.g. whitespace-only), returns
    /// the full text as a single element so the caller always has something to speak.
    static func splitIntoSentences(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text

        var sentences: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty {
                sentences.append(sentence)
            }
            return true
        }

        return sentences.isEmpty ? [text] : sentences
    }
}
