//
//  OpenAIAudioTranscriptionProvider.swift
//  leanring-buddy
//
//  AI transcription provider backed by OpenAI's audio transcription API.
//

import AVFoundation
import Foundation

struct OpenAIAudioTranscriptionProviderError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

/// File-upload transcription provider for any OpenAI-compatible
/// `/v1/audio/transcriptions` endpoint (OpenAI Whisper, Mistral Voxtral,
/// local Voicebox/Whisper, LM Studio, …).
///
/// Defaults reproduce the original OpenAI-only behavior: when constructed
/// with no arguments it reads the key/model from `AppBundleConfiguration`
/// and targets `https://api.openai.com`. Pass `baseURL`/`model`/`apiKey`
/// explicitly to point it at any other compatible server.
final class OpenAIAudioTranscriptionProvider: BuddyTranscriptionProvider {
    private let baseURL: String
    private let apiKey: String?
    private let modelName: String
    let displayName: String

    let requiresSpeechRecognitionPermission = false

    init(
        baseURL: String = "https://api.openai.com",
        apiKey: String? = AppBundleConfiguration.stringValue(forKey: "OpenAIAPIKey"),
        model: String = AppBundleConfiguration.stringValue(forKey: "OpenAITranscriptionModel")
            ?? "gpt-4o-transcribe",
        displayName: String = "OpenAI"
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.modelName = model
        self.displayName = displayName
    }

    /// Local servers (Voicebox, LM Studio, …) often need no key, so they are
    /// configured as long as a base URL is present. The hosted OpenAI default
    /// still requires a key.
    private var requiresAPIKey: Bool {
        let normalized = baseURL.lowercased()
        return normalized.contains("api.openai.com") || normalized.contains("api.mistral.ai")
    }

    var isConfigured: Bool {
        guard !baseURL.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return requiresAPIKey ? apiKey != nil : true
    }

    var unavailableExplanation: String? {
        guard !isConfigured else { return nil }
        return "\(displayName) transcription is not configured. Add an API key in Settings."
    }

    private var transcriptionURL: URL? {
        let trimmedBaseURL = baseURL.trimmingCharacters(in: .whitespaces)
        let normalizedBaseURL = trimmedBaseURL.hasSuffix("/")
            ? String(trimmedBaseURL.dropLast())
            : trimmedBaseURL
        return URL(string: "\(normalizedBaseURL)/v1/audio/transcriptions")
    }

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        guard isConfigured else {
            throw OpenAIAudioTranscriptionProviderError(
                message: unavailableExplanation ?? "\(displayName) transcription is not configured."
            )
        }

        guard let transcriptionURL else {
            throw OpenAIAudioTranscriptionProviderError(
                message: "\(displayName) transcription has an invalid base URL."
            )
        }

        return OpenAIAudioTranscriptionSession(
            transcriptionURL: transcriptionURL,
            apiKey: apiKey,
            modelName: modelName,
            providerDisplayName: displayName,
            keyterms: keyterms,
            onTranscriptUpdate: onTranscriptUpdate,
            onFinalTranscriptReady: onFinalTranscriptReady,
            onError: onError
        )
    }
}

private final class OpenAIAudioTranscriptionSession: BuddyStreamingTranscriptionSession {
    let finalTranscriptFallbackDelaySeconds: TimeInterval = 8.0

    private struct TranscriptionResponse: Decodable {
        let text: String
    }

    private static let targetSampleRate = 16_000

    private let transcriptionURL: URL
    private let apiKey: String?
    private let modelName: String
    private let providerDisplayName: String
    private let keyterms: [String]
    private let onTranscriptUpdate: (String) -> Void
    private let onFinalTranscriptReady: (String) -> Void
    private let onError: (Error) -> Void

    private let stateQueue = DispatchQueue(label: "com.learningbuddy.openai.transcription")
    private let audioPCM16Converter = BuddyPCM16AudioConverter(
        targetSampleRate: Double(targetSampleRate)
    )
    private let urlSession: URLSession

    private var bufferedPCM16AudioData = Data()
    private var hasRequestedFinalTranscript = false
    private var hasDeliveredFinalTranscript = false
    private var isCancelled = false
    private var transcriptionUploadTask: Task<Void, Never>?

    init(
        transcriptionURL: URL,
        apiKey: String?,
        modelName: String,
        providerDisplayName: String,
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.transcriptionURL = transcriptionURL
        self.apiKey = apiKey
        self.modelName = modelName
        self.providerDisplayName = providerDisplayName
        self.keyterms = keyterms
        self.onTranscriptUpdate = onTranscriptUpdate
        self.onFinalTranscriptReady = onFinalTranscriptReady
        self.onError = onError

        let urlSessionConfiguration = URLSessionConfiguration.default
        urlSessionConfiguration.timeoutIntervalForRequest = 45
        urlSessionConfiguration.timeoutIntervalForResource = 90
        urlSessionConfiguration.waitsForConnectivity = true
        self.urlSession = URLSession(configuration: urlSessionConfiguration)
    }

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        guard let audioPCM16Data = audioPCM16Converter.convertToPCM16Data(from: audioBuffer),
              !audioPCM16Data.isEmpty else {
            return
        }

        stateQueue.async {
            guard !self.hasRequestedFinalTranscript, !self.isCancelled else { return }
            self.bufferedPCM16AudioData.append(audioPCM16Data)
        }
    }

    func requestFinalTranscript() {
        stateQueue.async {
            guard !self.hasRequestedFinalTranscript, !self.isCancelled else { return }
            self.hasRequestedFinalTranscript = true

            let bufferedPCM16AudioData = self.bufferedPCM16AudioData
            self.transcriptionUploadTask = Task { [weak self] in
                await self?.transcribeBufferedAudio(bufferedPCM16AudioData)
            }
        }
    }

    func cancel() {
        // [weak self] is essential: cancel() is also called from deinit, and a
        // strong self capture in an escaping async block during deallocation
        // resurrects a zero-refcount object → swift_deallocClassInstance fatalError.
        stateQueue.async { [weak self] in
            self?.isCancelled = true
            self?.bufferedPCM16AudioData.removeAll(keepingCapacity: false)
        }

        transcriptionUploadTask?.cancel()
        urlSession.invalidateAndCancel()
    }

    private func transcribeBufferedAudio(_ bufferedPCM16AudioData: Data) async {
        guard !Task.isCancelled else { return }

        let trimmedAudioDataIsEmpty = stateQueue.sync {
            isCancelled || bufferedPCM16AudioData.isEmpty
        }

        if trimmedAudioDataIsEmpty {
            deliverFinalTranscript("")
            return
        }

        let wavAudioData = BuddyWAVFileBuilder.buildWAVData(
            fromPCM16MonoAudio: bufferedPCM16AudioData,
            sampleRate: Self.targetSampleRate
        )

        do {
            let transcriptText = try await requestTranscription(for: wavAudioData)
            guard !stateQueue.sync(execute: { isCancelled }) else { return }

            if !transcriptText.isEmpty {
                onTranscriptUpdate(transcriptText)
            }

            deliverFinalTranscript(transcriptText)
        } catch {
            guard !stateQueue.sync(execute: { isCancelled }) else { return }
            print("[\(providerDisplayName) Transcription] ❌ Upload failed (audio size: \(wavAudioData.count) bytes): \(error.localizedDescription)")
            onError(error)
        }
    }

    private func requestTranscription(for wavAudioData: Data) async throws -> String {
        let multipartBoundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: transcriptionURL)
        request.httpMethod = "POST"
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("multipart/form-data; boundary=\(multipartBoundary)", forHTTPHeaderField: "Content-Type")

        let requestBodyData = makeMultipartRequestBody(
            boundary: multipartBoundary,
            wavAudioData: wavAudioData
        )
        request.httpBody = requestBodyData

        let (responseData, response) = try await urlSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIAudioTranscriptionProviderError(
                message: "\(providerDisplayName) transcription returned an invalid response."
            )
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let responseText = String(data: responseData, encoding: .utf8) ?? "Unknown error"
            throw OpenAIAudioTranscriptionProviderError(
                message: "\(providerDisplayName) transcription failed: \(responseText)"
            )
        }

        if let transcriptionResponse = try? JSONDecoder().decode(
            TranscriptionResponse.self,
            from: responseData
        ) {
            return transcriptionResponse.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let responseText = String(data: responseData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if !responseText.isEmpty {
            return responseText
        }

        throw OpenAIAudioTranscriptionProviderError(
            message: "\(providerDisplayName) transcription returned an empty transcript."
        )
    }

    private func makeMultipartRequestBody(
        boundary: String,
        wavAudioData: Data
    ) -> Data {
        var requestBodyData = Data()

        requestBodyData.appendMultipartFormField(
            named: "model",
            value: modelName,
            usingBoundary: boundary
        )
        requestBodyData.appendMultipartFormField(
            named: "language",
            value: "en",
            usingBoundary: boundary
        )
        requestBodyData.appendMultipartFormField(
            named: "response_format",
            value: "json",
            usingBoundary: boundary
        )

        if let contextualPrompt = transcriptionPromptText() {
            requestBodyData.appendMultipartFormField(
                named: "prompt",
                value: contextualPrompt,
                usingBoundary: boundary
            )
        }

        requestBodyData.appendMultipartFileField(
            named: "file",
            filename: "voice-input.wav",
            mimeType: "audio/wav",
            fileData: wavAudioData,
            usingBoundary: boundary
        )
        requestBodyData.appendString("--\(boundary)--\r\n")

        return requestBodyData
    }

    private func transcriptionPromptText() -> String? {
        let normalizedKeyterms = keyterms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !normalizedKeyterms.isEmpty else { return nil }

        return """
        This is a short push-to-talk transcript for a coding and product app. Expect product names, technical terms, and app-specific vocabulary such as: \(normalizedKeyterms.joined(separator: ", ")).
        """
    }

    private func deliverFinalTranscript(_ transcriptText: String) {
        guard !hasDeliveredFinalTranscript else { return }
        hasDeliveredFinalTranscript = true
        onFinalTranscriptReady(transcriptText)
    }

    deinit {
        // Only synchronous, non-self-escaping teardown here. Do NOT call cancel()
        // (its stateQueue.async would re-reference self mid-deallocation and crash).
        transcriptionUploadTask?.cancel()
        urlSession.invalidateAndCancel()
    }
}

private extension Data {
    mutating func appendString(_ string: String) {
        append(string.data(using: .utf8)!)
    }

    mutating func appendMultipartFormField(
        named fieldName: String,
        value: String,
        usingBoundary boundary: String
    ) {
        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"\(fieldName)\"\r\n\r\n")
        appendString("\(value)\r\n")
    }

    mutating func appendMultipartFileField(
        named fieldName: String,
        filename: String,
        mimeType: String,
        fileData: Data,
        usingBoundary boundary: String
    ) {
        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(filename)\"\r\n")
        appendString("Content-Type: \(mimeType)\r\n\r\n")
        append(fileData)
        appendString("\r\n")
    }
}
