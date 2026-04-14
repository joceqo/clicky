//
//  ApfelAPI.swift
//  On-device LLM via Apple Intelligence (FoundationModels framework)
//
//  Uses Apple's built-in on-device language model directly — no server,
//  no API keys, no network. Text-only (no vision support).
//  Requires macOS 26+ with Apple Intelligence enabled.
//

import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// On-device text-only LLM using Apple Intelligence.
/// Gated behind macOS 26 — callers must check `isAvailable` before use.
@MainActor
class ApfelAPI {

    /// Whether Apple Intelligence is available on this device and OS version.
    var isAvailable: Bool {
        if #available(macOS 26.0, *) {
            #if canImport(FoundationModels)
            return SystemLanguageModel.default.availability == .available
            #else
            return false
            #endif
        }
        return false
    }

    /// Sends a text-only prompt to Apple's on-device model.
    /// Returns the full response text and duration.
    func chat(
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String
    ) async throws -> (text: String, duration: TimeInterval) {
        guard #available(macOS 26.0, *) else {
            throw NSError(
                domain: "ApfelAPI",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Apple Intelligence requires macOS 26 or newer."]
            )
        }

        #if canImport(FoundationModels)
        let startTime = Date()

        guard isAvailable else {
            throw NSError(
                domain: "ApfelAPI",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Apple Intelligence is not available. Check Settings > Apple Intelligence."]
            )
        }

        let session = LanguageModelSession(instructions: systemPrompt)

        // Replay conversation history so the model has prior context.
        // LanguageModelSession doesn't allow injecting assistant messages
        // directly, so we send each prior user turn to build up context.
        // The model's own responses will differ from the originals, but
        // the user turns provide enough conversational continuity.
        for (userMessage, _) in conversationHistory {
            _ = try await session.respond(to: userMessage)
        }

        print("🍎 Apple Intelligence request: \(conversationHistory.count + 1) turns")

        let response = try await session.respond(to: userPrompt)
        let responseText = response.content

        let duration = Date().timeIntervalSince(startTime)
        print("🍎 Apple Intelligence response: \(responseText.count) chars in \(String(format: "%.1f", duration))s")
        return (text: responseText, duration: duration)
        #else
        throw NSError(
            domain: "ApfelAPI",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "FoundationModels framework not available in this build."]
        )
        #endif
    }
}
