//
//  BrainClient.swift
//  leanring-buddy
//
//  Protocol for pluggable AI reasoning backends (the "brain" slot in the
//  STT → Brain → TTS pipeline). Any adapter that can accept labeled screenshots
//  plus a prompt and stream back text conforms to this protocol.
//
//  Current adapters: ClaudeAPI (Anthropic), OpenAICompatibleBrainAdapter (OpenAI / Ollama / LM Studio).
//

import Foundation

/// A pluggable AI vision + reasoning backend.
///
/// The contract is intentionally close to the existing `ClaudeAPI` surface so the
/// migration cost for existing call sites is minimal:
/// - `analyzeImageStreaming` is the hot path; it streams text chunks to the caller.
/// - `analyzeImage` is the non-streaming fallback used where progressive display isn't needed.
/// - `model` is mutable so the model picker in the UI can swap it at runtime.
protocol BrainClient: AnyObject {

    /// The model identifier sent with every request (e.g. "claude-sonnet-4-6", "gpt-4o").
    var model: String { get set }

    /// Sends images + prompt to the backend with streaming enabled.
    /// `onTextChunk` is called on the main actor each time a new chunk of text arrives
    /// so the UI can update progressively. Returns the full accumulated text and wall-clock
    /// duration when the stream ends.
    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval)

    /// Non-streaming variant. Sends images + prompt and returns the full response text
    /// and duration in one shot. Used for short analytical requests where progressive
    /// display isn't needed (e.g. the onboarding demo element detection).
    func analyzeImage(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String
    ) async throws -> (text: String, duration: TimeInterval)
}
