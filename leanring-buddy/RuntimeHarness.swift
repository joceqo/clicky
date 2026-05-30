//
//  RuntimeHarness.swift
//  leanring-buddy
//
//  Protocol for pluggable runtime harnesses (the "brain" + "runtime" tier).
//  Adapters: APIHarnessAdapter (HTTP vision+stream, default), with codex /
//  claude-code / opencode adapters added later.
//
//  A harness receives a booted session context and turns, and fires back
//  token deltas + a final response so the coordinator can emit events.
//

import Foundation

// MARK: - Protocol

/// A pluggable AI reasoning harness. Receives turns from the RuntimeCoordinator
/// and delivers token deltas + final responses via async callbacks.
protocol RuntimeHarness: AnyObject {
    var harnessType: HarnessType { get }
    var capabilities: HarnessCapabilities { get }

    /// Called once when a session is booted. Use for any warm-up or context setup.
    func boot(session: RuntimeSession) async throws

    /// Sends a voice turn (transcript + labeled screenshots) to the backend.
    /// - `onTokenDelta`: called for each streaming token chunk (NOT accumulated)
    /// - Returns: full response text when streaming completes
    func sendVoiceTurn(
        turnId: String,
        transcript: String,
        images: [(data: Data, label: String)],
        conversationHistory: [(userTranscript: String, assistantResponse: String)],
        systemPrompt: String,
        onTokenDelta: @escaping @MainActor (String) -> Void
    ) async throws -> String

    /// Sends a plain-text turn (no screenshot context).
    func sendTextTurn(
        turnId: String,
        text: String,
        conversationHistory: [(userTranscript: String, assistantResponse: String)],
        systemPrompt: String,
        onTokenDelta: @escaping @MainActor (String) -> Void
    ) async throws -> String

    /// Interrupts the current in-flight turn, if any.
    func interrupt() async

    /// Tears down the harness (called when the session ends).
    func stop() async
}

// MARK: - APIHarnessAdapter

/// Harness adapter backed by a BrainClient (ClaudeAPI or OpenAICompatibleBrainAdapter).
/// This is the simplest harness: pure HTTP request/response with streaming.
/// No subprocess, no stdio, no app-server bridge — just network calls.
final class APIHarnessAdapter: RuntimeHarness {
    let harnessType: HarnessType = .api
    let capabilities: HarnessCapabilities = .defaultAPI

    private let brainClient: any BrainClient
    private var currentTurnTask: Task<Void, Never>?

    init(brainClient: any BrainClient) {
        self.brainClient = brainClient
    }

    func boot(session: RuntimeSession) async throws {
        // No warm-up needed for HTTP; TLS warmup already done in ClaudeAPI.init
    }

    func sendVoiceTurn(
        turnId: String,
        transcript: String,
        images: [(data: Data, label: String)],
        conversationHistory: [(userTranscript: String, assistantResponse: String)],
        systemPrompt: String,
        onTokenDelta: @escaping @MainActor (String) -> Void
    ) async throws -> String {
        let historyForBrain = conversationHistory.map { entry in
            (userPlaceholder: entry.userTranscript, assistantResponse: entry.assistantResponse)
        }

        var previousAccumulated = ""
        let (fullText, _) = try await brainClient.analyzeImageStreaming(
            images: images,
            systemPrompt: systemPrompt,
            conversationHistory: historyForBrain,
            userPrompt: transcript,
            onTextChunk: { @MainActor accumulated in
                // Convert accumulated → delta so callers receive incremental chunks
                let delta = String(accumulated.dropFirst(previousAccumulated.count))
                previousAccumulated = accumulated
                onTokenDelta(delta)
            }
        )
        return fullText
    }

    func sendTextTurn(
        turnId: String,
        text: String,
        conversationHistory: [(userTranscript: String, assistantResponse: String)],
        systemPrompt: String,
        onTokenDelta: @escaping @MainActor (String) -> Void
    ) async throws -> String {
        let historyForBrain = conversationHistory.map { entry in
            (userPlaceholder: entry.userTranscript, assistantResponse: entry.assistantResponse)
        }

        var previousAccumulated = ""
        let (fullText, _) = try await brainClient.analyzeImageStreaming(
            images: [],
            systemPrompt: systemPrompt,
            conversationHistory: historyForBrain,
            userPrompt: text,
            onTextChunk: { @MainActor accumulated in
                let delta = String(accumulated.dropFirst(previousAccumulated.count))
                previousAccumulated = accumulated
                onTokenDelta(delta)
            }
        )
        return fullText
    }

    func interrupt() async {
        currentTurnTask?.cancel()
        currentTurnTask = nil
    }

    func stop() async {
        currentTurnTask?.cancel()
        currentTurnTask = nil
    }
}
