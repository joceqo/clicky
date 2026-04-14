//
//  OpenAIAPI.swift
//  OpenAI API Implementation
//

import Foundation

/// OpenAI-compatible API helper for vision analysis.
/// Works with OpenAI, LM Studio, and any server exposing the /v1/chat/completions endpoint.
class OpenAIAPI {
    var apiKey: String
    var apiURL: URL
    var model: String
    private let session: URLSession

    init(apiKey: String = "", apiURL: URL = URL(string: "http://127.0.0.1:1234/v1/chat/completions")!, model: String = "") {
        self.apiKey = apiKey
        self.apiURL = apiURL
        self.model = model

        // Use .default instead of .ephemeral so TLS session tickets are cached.
        // Ephemeral sessions do a full TLS handshake on every request, which causes
        // transient -1200 (errSSLPeerHandshakeFail) errors with large image payloads.
        // Disable URL/cookie caching to avoid storing responses or credentials on disk.
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        config.waitsForConnectivity = true
        config.urlCache = nil
        config.httpCookieStorage = nil
        self.session = URLSession(configuration: config)

        // Fire a lightweight HEAD request in the background to pre-establish the TLS
        // connection. This caches the TLS session ticket so the first real API call
        // (which carries a large image payload) doesn't need a cold TLS handshake.
        warmUpTLSConnection()
    }

    /// Sends a no-op HEAD request to the API host to establish and cache a TLS session.
    /// Failures are silently ignored — this is purely an optimization.
    private func warmUpTLSConnection() {
        var warmupRequest = URLRequest(url: apiURL)
        warmupRequest.httpMethod = "HEAD"
        warmupRequest.timeoutInterval = 10
        session.dataTask(with: warmupRequest) { _, _, _ in
            // Response doesn't matter — the TLS handshake is the goal
        }.resume()
    }

    /// Send a vision request to OpenAI with one or more labeled images.
    func analyzeImage(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = Date()

        // Build request
        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Build messages array
        var messages: [[String: Any]] = []

        // Add system message first
        messages.append([
            "role": "system",
            "content": systemPrompt
        ])

        // Add conversation history
        for (userPlaceholder, assistantResponse) in conversationHistory {
            messages.append(["role": "user", "content": userPlaceholder])
            messages.append(["role": "assistant", "content": assistantResponse])
        }

        // Build current message with all labeled images + prompt
        var contentBlocks: [[String: Any]] = []
        for image in images {
            contentBlocks.append([
                "type": "text",
                "text": image.label
            ])
            contentBlocks.append([
                "type": "image_url",
                "image_url": [
                    "url": "data:image/jpeg;base64,\(image.data.base64EncodedString())"
                ]
            ])
        }
        contentBlocks.append([
            "type": "text",
            "text": userPrompt
        ])
        messages.append(["role": "user", "content": contentBlocks])

        // Build request body
        let body: [String: Any] = [
            "model": model,
            // `max_tokens` is deprecated/incompatible for some newer OpenAI models.
            "max_completion_tokens": 600,
            "messages": messages
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData
        let payloadMB = Double(bodyData.count) / 1_048_576.0
        print("🌐 OpenAI request: \(String(format: "%.1f", payloadMB))MB, \(images.count) image(s)")

        // Send request
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let responseString = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(
                domain: "OpenAIAPI",
                code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                userInfo: [NSLocalizedDescriptionKey: "API Error: \(responseString)"]
            )
        }

        // Parse response
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let choices = json?["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let text = message["content"] as? String else {
            throw NSError(
                domain: "OpenAIAPI",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid response format"]
            )
        }

        let duration = Date().timeIntervalSince(startTime)
        return (text: text, duration: duration)
    }

    /// Send a streaming vision request using SSE (Server-Sent Events).
    /// Matches the ClaudeAPI.analyzeImageStreaming() signature so callers can
    /// swap between Claude and LM Studio with the same interface.
    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = Date()

        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Build messages array
        var messages: [[String: Any]] = []

        messages.append([
            "role": "system",
            "content": systemPrompt
        ])

        for (userPlaceholder, assistantResponse) in conversationHistory {
            messages.append(["role": "user", "content": userPlaceholder])
            messages.append(["role": "assistant", "content": assistantResponse])
        }

        // Build current message with all labeled images + prompt
        var contentBlocks: [[String: Any]] = []
        for image in images {
            contentBlocks.append([
                "type": "text",
                "text": image.label
            ])
            contentBlocks.append([
                "type": "image_url",
                "image_url": [
                    "url": "data:image/jpeg;base64,\(image.data.base64EncodedString())"
                ]
            ])
        }
        contentBlocks.append([
            "type": "text",
            "text": userPrompt
        ])
        messages.append(["role": "user", "content": contentBlocks])

        let body: [String: Any] = [
            "model": model,
            "max_completion_tokens": 600,
            "stream": true,
            "messages": messages
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData
        let payloadMB = Double(bodyData.count) / 1_048_576.0
        print("🌐 OpenAI streaming request: \(String(format: "%.1f", payloadMB))MB, \(images.count) image(s)")

        // Stream SSE response
        let (bytes, response) = try await session.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            // Try to read the error body for diagnostics
            var errorBody = ""
            for try await line in bytes.lines {
                errorBody += line
            }
            throw NSError(
                domain: "OpenAIAPI",
                code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                userInfo: [NSLocalizedDescriptionKey: "API Error: \(errorBody)"]
            )
        }

        var fullText = ""
        for try await line in bytes.lines {
            guard !Task.isCancelled else { break }

            // SSE format: "data: {json}" or "data: [DONE]"
            guard line.hasPrefix("data: ") else { continue }
            let jsonString = String(line.dropFirst(6))
            if jsonString == "[DONE]" { break }

            guard let jsonData = jsonString.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let firstChoice = choices.first,
                  let delta = firstChoice["delta"] as? [String: Any],
                  let content = delta["content"] as? String else {
                continue
            }

            fullText += content
            await onTextChunk(content)
        }

        let duration = Date().timeIntervalSince(startTime)
        return (text: fullText, duration: duration)
    }
}
