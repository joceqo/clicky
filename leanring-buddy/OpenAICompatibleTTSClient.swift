//
//  OpenAICompatibleTTSClient.swift
//  leanring-buddy
//
//  TTSClient adapter for any server that speaks the OpenAI /v1/audio/speech
//  request format. A single class covers all of:
//
//    • Voicebox local   — http://127.0.0.1:8880   (no key, model: kokoro/parler-tts/…)
//    • OpenAI TTS       — https://api.openai.com   (key, model: tts-1 / tts-1-hd)
//    • Voxtral (Mistral)— https://api.mistral.ai   (key, model: mistral-tts-latest)
//    • Any other OpenAI-compat TTS server
//
//  Configure via TTSProviderSettings; create via TTSProviderFactory.
//

import AVFoundation
import Foundation

@MainActor
final class OpenAICompatibleTTSClient: TTSClient {
    private let speechURL: URL
    private let model: String
    private let voice: String
    private let speed: Double
    private let apiKey: String?
    private let session: URLSession

    private var audioPlayer: AVAudioPlayer?
    private var pendingPlaybackDelegate: TTSAudioPlaybackDelegate?

    /// - Parameters:
    ///   - baseURL: Root URL of the TTS server (e.g. `"http://127.0.0.1:8880"`).
    ///              The adapter appends `/v1/audio/speech`.
    ///   - model:   Model slug (e.g. `"kokoro"`, `"tts-1"`, `"mistral-tts-latest"`).
    ///   - voice:   Voice identifier for the model (e.g. `"af_heart"`, `"nova"`, `"alloy"`).
    ///   - apiKey:  Bearer token. Pass `nil` for local servers that need no auth.
    ///   - speed:   Playback speed multiplier. Default 1.0.
    init(
        baseURL: String,
        model: String,
        voice: String,
        apiKey: String? = nil,
        speed: Double = 1.0
    ) {
        self.speechURL = URL(string: "\(baseURL)/v1/audio/speech")!
        self.model = model
        self.voice = voice
        self.apiKey = apiKey
        self.speed = speed

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 120
        self.session = URLSession(configuration: configuration)
    }

    // MARK: - TTSClient

    var isPlaying: Bool { audioPlayer?.isPlaying ?? false }

    func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
        pendingPlaybackDelegate?.resumeIfPending()
        pendingPlaybackDelegate = nil
    }

    func speakText(_ text: String) async throws {
        var request = URLRequest(url: speechURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        // `speed` is applied at playback (AVAudioPlayer.rate) rather than sent in
        // the body — the hosted Mistral endpoint rejects a `speed` field (422),
        // and local playback rate speeds up the voice uniformly across providers.
        let requestBody: [String: Any] = [
            "model": model,
            "input": text,
            "voice": voice,
            "response_format": "mp3"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (audioData, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "OpenAICompatTTS", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid response from TTS server"])
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: audioData, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "OpenAICompatTTS", code: httpResponse.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "TTS error (\(httpResponse.statusCode)): \(errorBody)"])
        }

        let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "?"
        print("🔊 TTS \(self.model)/\(self.voice): HTTP \(httpResponse.statusCode), \(audioData.count) bytes, content-type=\(contentType)")

        // Some servers (e.g. Mistral Voxtral) return JSON with base64-encoded
        // audio in an `audio_data` field instead of raw audio bytes. Unwrap it.
        var playableData = audioData
        if contentType.contains("json") || audioData.first == UInt8(ascii: "{") {
            if let json = try? JSONSerialization.jsonObject(with: audioData) as? [String: Any],
               let base64 = (json["audio_data"] ?? json["audio"]) as? String,
               let decoded = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) {
                playableData = decoded
                print("🔊 TTS: unwrapped base64 audio_data → \(decoded.count) bytes")
            } else {
                print("⚠️ TTS: JSON response but no decodable audio_data field")
            }
        }

        try Task.checkCancellation()

        try await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                do {
                    let player = try AVAudioPlayer(data: playableData)
                    player.enableRate = true
                    player.rate = Float(self.speed)
                    let delegate = TTSAudioPlaybackDelegate(continuation: continuation)
                    self.pendingPlaybackDelegate = delegate
                    player.delegate = delegate
                    self.audioPlayer = player
                    player.play()
                    print("🔊 OpenAI-compat TTS (\(self.model)/\(self.voice)): playing \(playableData.count / 1024)KB")
                } catch {
                    let preview = String(data: playableData.prefix(180), encoding: .utf8)
                        ?? "<binary: \(audioData.prefix(8).map { String(format: "%02x", $0) }.joined(separator: " "))>"
                    print("⚠️ TTS playback decode failed: \(error.localizedDescription) — body preview: \(preview)")
                    continuation.resume()
                }
            }
            self.audioPlayer = nil
            self.pendingPlaybackDelegate = nil
            try Task.checkCancellation()
        } onCancel: {
            Task { @MainActor [weak self] in self?.stopPlayback() }
        }
    }
}
