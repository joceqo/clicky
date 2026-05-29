//
//  OpenAICompatibleBrainAdapter.swift
//  leanring-buddy
//
//  BrainClient adapter for any OpenAI-format chat-completions endpoint:
//  OpenAI (GPT-4o, GPT-4-vision-preview), local Ollama, LM Studio,
//  and any other OpenAI-compatible server.
//
//  Image encoding uses base64 data-URL `image_url` blocks (the OpenAI format),
//  which differs from Anthropic's `source.base64` format in ClaudeAPI.
//

import Foundation

final class OpenAICompatibleBrainAdapter: BrainClient {
    var model: String

    private let chatCompletionsURL: URL
    private let apiKey: String?
    private let session: URLSession

    /// - Parameters:
    ///   - baseURL: Root URL of the server, e.g. `"https://api.openai.com"` or
    ///              `"http://localhost:11434"` for Ollama. The adapter appends
    ///              `/v1/chat/completions`.
    ///   - model:   Model name to send in every request.
    ///   - apiKey:  Bearer token. Pass `nil` for local servers that require no auth.
    init(baseURL: String, model: String, apiKey: String? = nil) {
        self.model = model
        self.apiKey = apiKey
        self.chatCompletionsURL = URL(string: "\(baseURL)/v1/chat/completions")!

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        config.waitsForConnectivity = true
        config.urlCache = nil
        config.httpCookieStorage = nil
        self.session = URLSession(configuration: config)
    }

    // MARK: - BrainClient

    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = Date()

        var request = makeRequest()
        let messages = buildMessages(
            images: images,
            systemPrompt: systemPrompt,
            conversationHistory: conversationHistory,
            userPrompt: userPrompt
        )

        let body: [String: Any] = [
            "model": model,
            "messages": messages,
            "max_tokens": 1024,
            "stream": true
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData
        let payloadMB = Double(bodyData.count) / 1_048_576.0
        print("🌐 OpenAI-compat streaming request: \(String(format: "%.1f", payloadMB))MB, \(images.count) image(s), model: \(model)")

        let (byteStream, response) = try await session.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "OpenAIBrain", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"])
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            var errorBodyLines: [String] = []
            for try await line in byteStream.lines {
                errorBodyLines.append(line)
            }
            throw NSError(
                domain: "OpenAIBrain",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "API error (\(httpResponse.statusCode)): \(errorBodyLines.joined(separator: "\n"))"]
            )
        }

        var accumulatedResponseText = ""

        for try await line in byteStream.lines {
            guard line.hasPrefix("data: ") else { continue }
            let jsonString = String(line.dropFirst(6))
            guard jsonString != "[DONE]" else { break }

            guard let jsonData = jsonString.data(using: .utf8),
                  let eventPayload = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let choices = eventPayload["choices"] as? [[String: Any]],
                  let firstChoice = choices.first,
                  let delta = firstChoice["delta"] as? [String: Any],
                  let textChunk = delta["content"] as? String else {
                continue
            }

            accumulatedResponseText += textChunk
            let currentAccumulatedText = accumulatedResponseText
            await onTextChunk(currentAccumulatedText)
        }

        let duration = Date().timeIntervalSince(startTime)
        return (text: accumulatedResponseText, duration: duration)
    }

    func analyzeImage(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = Date()

        var request = makeRequest()
        let messages = buildMessages(
            images: images,
            systemPrompt: systemPrompt,
            conversationHistory: conversationHistory,
            userPrompt: userPrompt
        )

        let body: [String: Any] = [
            "model": model,
            "messages": messages,
            "max_tokens": 256
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData
        let payloadMB = Double(bodyData.count) / 1_048_576.0
        print("🌐 OpenAI-compat request: \(String(format: "%.1f", payloadMB))MB, \(images.count) image(s), model: \(model)")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let responseBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(
                domain: "OpenAIBrain",
                code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                userInfo: [NSLocalizedDescriptionKey: "API error: \(responseBody)"]
            )
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let text = message["content"] as? String else {
            throw NSError(domain: "OpenAIBrain", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid response format"])
        }

        let duration = Date().timeIntervalSince(startTime)
        return (text: text, duration: duration)
    }

    // MARK: - Private

    private func makeRequest() -> URLRequest {
        var request = URLRequest(url: chatCompletionsURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if let apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        return request
    }

    /// Builds the `messages` array in OpenAI chat-completions format.
    /// Images are encoded as base64 data-URL `image_url` blocks. Each image is
    /// followed by its label as a `text` block — same labeling convention as ClaudeAPI
    /// so the model sees dimension annotations and screen identifiers.
    private func buildMessages(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String
    ) -> [[String: Any]] {
        var messages: [[String: Any]] = []

        messages.append(["role": "system", "content": systemPrompt])

        for (userText, assistantText) in conversationHistory {
            messages.append(["role": "user", "content": userText])
            messages.append(["role": "assistant", "content": assistantText])
        }

        // Build the current user turn: interleaved image + label blocks, then the prompt
        var userContentBlocks: [[String: Any]] = []
        for image in images {
            let mimeType = detectImageMIMEType(for: image.data)
            let base64EncodedImageData = image.data.base64EncodedString()
            userContentBlocks.append([
                "type": "image_url",
                "image_url": ["url": "data:\(mimeType);base64,\(base64EncodedImageData)"]
            ])
            userContentBlocks.append(["type": "text", "text": image.label])
        }
        userContentBlocks.append(["type": "text", "text": userPrompt])

        messages.append(["role": "user", "content": userContentBlocks])

        return messages
    }

    /// Detects image MIME type from magic bytes.
    /// PNG files start with 89 50 4E 47; everything else is treated as JPEG.
    private func detectImageMIMEType(for imageData: Data) -> String {
        if imageData.count >= 4 {
            let pngMagicBytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
            if [UInt8](imageData.prefix(4)) == pngMagicBytes {
                return "image/png"
            }
        }
        return "image/jpeg"
    }
}
