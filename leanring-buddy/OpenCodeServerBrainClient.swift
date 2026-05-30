//
//  OpenCodeServerBrainClient.swift
//  leanring-buddy
//
//  BrainClient that talks to a persistent `opencode serve` HTTP server (managed by
//  OpenCodeServerManager) instead of spawning `opencode run` once per turn. The win
//  over CLIAgentBrainAdapter: no per-turn cold start, and a reused *session* keeps
//  multi-turn context on the server — so the second turn is much faster than the first.
//
//  Discovered OpenCode HTTP API (shapes taken from the opencode SDK source —
//  packages/sdk/js/src/gen/{types,sdk}.gen.ts — and verified end-to-end against a
//  live `opencode serve` 1.15.12: create-session, send-message, response parsing,
//  multi-turn session persistence, and the image-part schema all confirmed):
//
//    Create session:  POST /session
//                     body  { "title": "..." }
//                     resp  { "id": "...", ... }
//
//    Send a prompt:   POST /session/{id}/message      (blocks until the reply is done)
//                     body  {
//                       "model":  { "providerID": "...", "modelID": "..." },   // optional
//                       "system": "<system prompt>",                            // optional
//                       "parts":  [ TextPartInput | FilePartInput, ... ]
//                     }
//                     resp  { "info": Message, "parts": [Part] }
//
//    TextPartInput:   { "type": "text", "text": "..." }
//    FilePartInput:   { "type": "file", "mime": "image/png",
//                       "filename": "...", "url": "data:image/png;base64,..." }
//                     (images must be base64 data URLs; remote/file URLs are rejected)
//
//  The assistant's reply text is the concatenation of the response `parts` whose
//  "type" is "text".
//
//  Vision vs. text-only models: image file parts only work with a vision-capable
//  model. Text-only models (e.g. the free `opencode/*` models) reject an image turn
//  with HTTP 400. We detect that once, then fall back to on-device OCR — sending the
//  screenshot's recognized text instead of the image — so text-only models still work.
//
//  Streaming: the synchronous /message endpoint returns the full reply in one shot, so
//  `onTextChunk` is invoked once with the complete text. This matches the existing
//  CLIAgentBrainAdapter behavior and the voice pipeline (which doesn't render partial
//  chunks anyway — the spinner holds until TTS plays). Token-level streaming would use
//  the server's GET /event SSE stream; left as a follow-up.
//

import Foundation

@MainActor
final class OpenCodeServerBrainClient: BrainClient {

    /// Model selector in `providerID/modelID` form (e.g. "anthropic/claude-sonnet-4-5",
    /// "opencode/grok-code"). Empty, or any value without a "/", means "use the server's
    /// configured default model". Settable so the model picker doesn't break, though for
    /// OpenCode the model is normally chosen in Settings.
    var model: String

    /// Bare command name ("opencode") or an absolute path, forwarded to the server manager.
    private let binaryPath: String

    /// Lazily-created session id, reused on every subsequent turn → this is the
    /// persistence win (the server keeps the conversation context for this session).
    private var sessionID: String?

    /// Set once we learn (via an HTTP 400 on an image turn) that the configured model
    /// can't accept image attachments. After that we OCR screenshots to text instead
    /// of sending the image, so text-only models still work — just degraded to text.
    private var modelRejectedImages = false

    private let httpSession: URLSession

    init(model: String, binaryPath: String?) {
        self.model = model
        let trimmedBinaryPath = (binaryPath ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.binaryPath = trimmedBinaryPath.isEmpty ? "opencode" : trimmedBinaryPath

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 300
        configuration.waitsForConnectivity = true
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        self.httpSession = URLSession(configuration: configuration)
    }

    // MARK: - BrainClient

    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        let result = try await sendTurn(images: images, systemPrompt: systemPrompt, userPrompt: userPrompt)
        onTextChunk(result.text)
        return result
    }

    func analyzeImage(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String
    ) async throws -> (text: String, duration: TimeInterval) {
        try await sendTurn(images: images, systemPrompt: systemPrompt, userPrompt: userPrompt)
    }

    // MARK: - Core

    /// Note on `conversationHistory`: it's intentionally NOT resent. The OpenCode server
    /// keeps the conversation for our reused session, so resending prior turns would
    /// duplicate context. Relying on the server-side session is the whole point of this
    /// provider.
    private func sendTurn(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        userPrompt: String
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = Date()

        let baseURL = try await OpenCodeServerManager.shared.ensureRunning(binaryPath: binaryPath)
        let sessionID = try await ensureSession(baseURL: baseURL)
        let messageURL = baseURL
            .appendingPathComponent("session")
            .appendingPathComponent(sessionID)
            .appendingPathComponent("message")

        // Send the screenshots as image attachments unless we've already learned this
        // model can't accept them (then go straight to OCR text).
        let sendImagesFirst = !modelRejectedImages && !images.isEmpty
        var parts = sendImagesFirst
            ? buildImageParts(images: images, userPrompt: userPrompt)
            : await buildOCRTextParts(images: images, userPrompt: userPrompt)

        var (data, httpResponse) = try await postMessage(
            url: messageURL, parts: parts, systemPrompt: systemPrompt
        )

        // A 400 on an image turn means the model isn't vision-capable. Remember that,
        // OCR the screenshots to text, and retry the same turn on the same session
        // (verified to stay usable after such a 400).
        if sendImagesFirst, httpResponse.statusCode == 400 {
            print("⚠️ opencode session \(sessionID): model rejected image attachments (HTTP 400) — retrying with on-device OCR text")
            modelRejectedImages = true
            parts = await buildOCRTextParts(images: images, userPrompt: userPrompt)
            (data, httpResponse) = try await postMessage(
                url: messageURL, parts: parts, systemPrompt: systemPrompt
            )
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let responseBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw OpenCodeServerError.requestFailed(statusCode: httpResponse.statusCode, body: responseBody)
        }

        let assistantText = try extractAssistantText(from: data)
        let elapsed = Date().timeIntervalSince(startTime)
        print("🤖 opencode session \(sessionID): turn \(userPrompt.count) chars + \(images.count) image(s) → \(assistantText.count) chars in \(String(format: "%.1f", elapsed))s")

        if assistantText.isEmpty {
            print("⚠️ opencode session \(sessionID): empty assistant text — response had no text parts")
        }

        return (text: assistantText, duration: elapsed)
    }

    /// Returns the existing session id, creating one on the first turn.
    private func ensureSession(baseURL: URL) async throws -> String {
        if let sessionID { return sessionID }

        let createSessionURL = baseURL.appendingPathComponent("session")
        let (data, httpResponse) = try await postJSON(
            url: createSessionURL,
            body: ["title": "Clicky voice session"]
        )

        guard (200...299).contains(httpResponse.statusCode) else {
            let responseBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw OpenCodeServerError.requestFailed(statusCode: httpResponse.statusCode, body: responseBody)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let newSessionID = json["id"] as? String else {
            let responseBody = String(data: data, encoding: .utf8) ?? "Unknown body"
            throw OpenCodeServerError.unexpectedResponse(detail: "create session returned no id: \(responseBody)")
        }

        sessionID = newSessionID
        print("🤖 opencode serve → created session \(newSessionID)")
        return newSessionID
    }

    // MARK: - Request / response shaping

    /// Posts a message turn (parts + system prompt + optional model) to the session.
    private func postMessage(
        url: URL,
        parts: [[String: Any]],
        systemPrompt: String
    ) async throws -> (Data, HTTPURLResponse) {
        var requestBody: [String: Any] = [
            "parts": parts,
            "system": systemPrompt
        ]
        if let modelSelector = modelSelector() {
            requestBody["model"] = modelSelector
        }
        return try await postJSON(url: url, body: requestBody)
    }

    /// Builds the `parts` array for a vision model: each screenshot as a base64
    /// data-URL file part, each followed by its label as a text part (same labeling
    /// convention as the other brain adapters), and finally the user's prompt.
    private func buildImageParts(
        images: [(data: Data, label: String)],
        userPrompt: String
    ) -> [[String: Any]] {
        var parts: [[String: Any]] = []

        for (index, image) in images.enumerated() {
            let mimeType = detectImageMIMEType(for: image.data)
            let fileExtension = (mimeType == "image/png") ? "png" : "jpg"
            let base64EncodedImage = image.data.base64EncodedString()
            parts.append([
                "type": "file",
                "mime": mimeType,
                "filename": "joceclicky-screen-\(index).\(fileExtension)",
                "url": "data:\(mimeType);base64,\(base64EncodedImage)"
            ])
            parts.append(["type": "text", "text": image.label])
        }

        parts.append(["type": "text", "text": userPrompt])
        return parts
    }

    /// Builds the `parts` array for a text-only model: each screenshot is OCR'd
    /// on-device (Vision) and sent as a labeled text part, then the user's prompt.
    /// OCR runs off the main actor; empty results degrade to "(no text detected)".
    private func buildOCRTextParts(
        images: [(data: Data, label: String)],
        userPrompt: String
    ) async -> [[String: Any]] {
        var parts: [[String: Any]] = []

        for image in images {
            let recognizedText = await Task.detached {
                ScreenshotTextRecognizer.recognizeText(in: image.data)
            }.value
            let screenText = recognizedText.isEmpty ? "(no text detected)" : recognizedText
            parts.append(["type": "text", "text": "Screen text from \(image.label):\n\(screenText)"])
        }

        parts.append(["type": "text", "text": userPrompt])
        return parts
    }

    /// Extracts the assistant's text from a `{ info, parts }` response by concatenating
    /// every part whose "type" is "text".
    private func extractAssistantText(from data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let parts = json["parts"] as? [[String: Any]] else {
            let responseBody = String(data: data, encoding: .utf8) ?? "Unknown body"
            throw OpenCodeServerError.unexpectedResponse(detail: "message response had no parts: \(responseBody)")
        }

        let assistantText = parts
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined()

        return assistantText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Parses `model` ("providerID/modelID") into the server's expected object.
    /// Returns nil when empty or not in `providerID/modelID` form, so the server falls
    /// back to its configured default model.
    private func modelSelector() -> [String: String]? {
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let slashIndex = trimmedModel.firstIndex(of: "/") else { return nil }

        let providerID = String(trimmedModel[trimmedModel.startIndex..<slashIndex])
        let modelID = String(trimmedModel[trimmedModel.index(after: slashIndex)...])
        guard !providerID.isEmpty, !modelID.isEmpty else { return nil }

        return ["providerID": providerID, "modelID": modelID]
    }

    private func postJSON(url: URL, body: [String: Any]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await httpSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenCodeServerError.unexpectedResponse(detail: "non-HTTP response from \(url.absoluteString)")
        }
        return (data, httpResponse)
    }

    /// Detects image MIME type from magic bytes. PNG starts with 89 50 4E 47;
    /// everything else is treated as JPEG.
    private func detectImageMIMEType(for imageData: Data) -> String {
        let pngMagicBytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
        if imageData.starts(with: pngMagicBytes) {
            return "image/png"
        }
        return "image/jpeg"
    }
}
