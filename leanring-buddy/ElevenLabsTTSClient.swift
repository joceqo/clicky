//
//  ElevenLabsTTSClient.swift
//  leanring-buddy
//
//  ElevenLabs TTS backend conforming to TTSClient. Uses the ElevenLabs
//  streaming endpoint via the Cloudflare Worker proxy so the API key never
//  ships in the binary.
//
//  speakText awaits full playback completion, enabling CompanionManager's
//  phrase-by-phrase loop. The shared TTSAudioPlaybackDelegate (TTSClient.swift)
//  bridges AVAudioPlayerDelegate → Swift concurrency continuation.
//

import AVFoundation
import Foundation

@MainActor
final class ElevenLabsTTSClient: TTSClient {
    private let proxyURL: URL
    private let session: URLSession

    private var audioPlayer: AVAudioPlayer?
    private var pendingPlaybackDelegate: TTSAudioPlaybackDelegate?

    init(proxyURL: String) {
        self.proxyURL = URL(string: proxyURL)!
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
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
        var request = URLRequest(url: proxyURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")

        let requestBody: [String: Any] = [
            "text": text,
            "model_id": "eleven_flash_v2_5",
            "voice_settings": ["stability": 0.5, "similarity_boost": 0.75]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (audioData, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "ElevenLabsTTS", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: audioData, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "ElevenLabsTTS", code: httpResponse.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "TTS API error (\(httpResponse.statusCode)): \(errorBody)"])
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
                    print("🔊 ElevenLabs TTS: playing \(audioData.count / 1024)KB audio")
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
