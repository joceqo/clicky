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

        let requestBody: [String: Any] = [
            "model": model,
            "input": text,
            "voice": voice,
            "response_format": "mp3",
            "speed": speed
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

        try Task.checkCancellation()

        try await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                do {
                    let player = try AVAudioPlayer(data: audioData)
                    let delegate = TTSAudioPlaybackDelegate(continuation: continuation)
                    self.pendingPlaybackDelegate = delegate
                    player.delegate = delegate
                    self.audioPlayer = player
                    player.play()
                    print("🔊 OpenAI-compat TTS (\(self.model)/\(self.voice)): playing \(audioData.count / 1024)KB")
                } catch {
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
