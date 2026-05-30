//
//  AppleOCRBrainAdapter.swift
//  leanring-buddy
//
//  A low-compute "brain" backend: instead of sending the screenshot to a vision
//  model, it runs on-device OCR (Vision framework) to extract the screen's text,
//  then reasons over that text with Apple's on-device LLM (ApfelAPI).
//
//  Trade-off: it can't "see" layout/images — only text it can OCR — so it's a
//  weaker brain. But it's fully local, free, and light on the Mac (no big VL
//  model, no GPU-heavy inference). Good as a cheap default / battery-friendly mode.
//
//  Requires macOS 26+ with Apple Intelligence enabled (via ApfelAPI).
//

import AppKit
import Foundation
import Vision

@MainActor
final class AppleOCRBrainAdapter: BrainClient {

    /// Unused (the Apple model isn't selectable), but required by BrainClient.
    var model: String = "apple-ocr"

    private let apfel = ApfelAPI()

    /// Whether Apple Intelligence is available; surfaced so the UI can warn.
    var isAvailable: Bool { apfel.isAvailable }

    // MARK: - BrainClient

    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        let result = try await run(images: images, systemPrompt: systemPrompt,
                                   conversationHistory: conversationHistory, userPrompt: userPrompt)
        onTextChunk(result.text)
        return result
    }

    func analyzeImage(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String
    ) async throws -> (text: String, duration: TimeInterval) {
        try await run(images: images, systemPrompt: systemPrompt,
                      conversationHistory: conversationHistory, userPrompt: userPrompt)
    }

    // MARK: - Core

    private func run(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String
    ) async throws -> (text: String, duration: TimeInterval) {
        // OCR each screenshot off the main actor, then reason over the text.
        let ocrBlocks: [String] = await withTaskGroup(of: (Int, String).self) { group in
            for (index, image) in images.enumerated() {
                group.addTask { (index, Self.recognizeText(in: image.data)) }
            }
            var collected: [(Int, String)] = []
            for await pair in group { collected.append(pair) }
            return collected.sorted { $0.0 < $1.0 }.map { $0.1 }
        }

        var screenText = ""
        for (block, label) in zip(ocrBlocks, images.map(\.label)) where !block.isEmpty {
            screenText += "\n--- \(label) ---\n\(block)\n"
        }

        // Apple Intelligence has a tiny ~4096-token context, so a text-heavy
        // screen otherwise blows it (exceededContextWindowSize). Cap the OCR text.
        let maxScreenChars = 6000
        if screenText.count > maxScreenChars {
            screenText = String(screenText.prefix(maxScreenChars)) + "\n…(screen text truncated)"
        }

        let composedPrompt: String
        if screenText.isEmpty {
            composedPrompt = userPrompt + "\n\n(No readable text was found on screen.)"
        } else {
            composedPrompt = userPrompt + "\n\nText currently visible on the user's screen (extracted via OCR):\n" + screenText
        }

        // Keep only the last couple of turns — replayed history also eats the
        // small context window.
        return try await apfel.chat(
            systemPrompt: systemPrompt,
            conversationHistory: Array(conversationHistory.suffix(2)),
            userPrompt: composedPrompt
        )
    }

    /// Runs Vision text recognition on image data. Nonisolated so it can run off
    /// the main actor. Returns recognized lines joined by newlines (empty on failure).
    nonisolated static func recognizeText(in data: Data) -> String {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return ""
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return ""
        }

        let lines = request.results?.compactMap { $0.topCandidates(1).first?.string } ?? []
        return lines.joined(separator: "\n")
    }
}
