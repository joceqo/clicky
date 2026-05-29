//
//  ElevenLabsTTSClient.swift
//  leanring-buddy
//
//  Streams text-to-speech audio from ElevenLabs and plays it back
//  through the system audio output. Conforms to TTSClient so it can
//  be swapped for other backends without changing call sites.
//
//  speakText now awaits full playback completion before returning, which
//  lets CompanionManager drive phrase-by-phrase TTS in a simple loop.
//

import AVFoundation
import Foundation

@MainActor
final class ElevenLabsTTSClient: TTSClient {
    private let proxyURL: URL
    private let session: URLSession

    /// The audio player for the current TTS playback. Kept alive so the
    /// audio finishes playing even if the caller doesn't hold a reference.
    private var audioPlayer: AVAudioPlayer?

    /// Holds the AVAudioPlayerDelegate for the current playback. The delegate
    /// owns the continuation that unblocks speakText when playback ends.
    private var pendingPlaybackDelegate: AudioPlaybackCompletionDelegate?

    init(proxyURL: String) {
        self.proxyURL = URL(string: proxyURL)!

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: configuration)
    }

    // MARK: - TTSClient

    /// Whether TTS audio is currently playing back.
    var isPlaying: Bool {
        audioPlayer?.isPlaying ?? false
    }

    /// Stops any in-progress playback immediately.
    /// Also resumes any pending continuation so callers awaiting speakText don't hang.
    func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
        pendingPlaybackDelegate?.resumeIfPending()
        pendingPlaybackDelegate = nil
    }

    /// Sends `text` to ElevenLabs TTS, plays the resulting audio, and **awaits
    /// completion** of playback before returning. This lets callers sequence
    /// multiple phrases in a simple `for` loop without polling `isPlaying`.
    ///
    /// Cancellation-safe: if the enclosing Task is cancelled, playback stops
    /// immediately and `CancellationError` is thrown.
    func speakText(_ text: String) async throws {
        var request = URLRequest(url: proxyURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")

        let requestBody: [String: Any] = [
            "text": text,
            "model_id": "eleven_flash_v2_5",
            "voice_settings": [
                "stability": 0.5,
                "similarity_boost": 0.75
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        // Network fetch — cancellable via normal Task cancellation
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

        // Play the audio and await completion. AudioPlaybackCompletionDelegate bridges
        // AVAudioPlayerDelegate callbacks (which fire on the audio thread) to the Swift
        // concurrency continuation. withTaskCancellationHandler ensures that if the
        // enclosing Task is cancelled, we stop the player and resume the continuation
        // rather than hanging indefinitely.
        try await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                do {
                    let player = try AVAudioPlayer(data: audioData)
                    let delegate = AudioPlaybackCompletionDelegate(continuation: continuation)
                    self.pendingPlaybackDelegate = delegate
                    player.delegate = delegate
                    self.audioPlayer = player
                    player.play()
                    print("🔊 ElevenLabs TTS: playing \(audioData.count / 1024)KB audio")
                } catch {
                    // AVAudioPlayer init failed — resume immediately so speakText doesn't hang
                    continuation.resume()
                }
            }
            // Clean up after natural completion
            self.audioPlayer = nil
            self.pendingPlaybackDelegate = nil
            // Throw CancellationError if the task was cancelled while audio was playing
            try Task.checkCancellation()
        } onCancel: {
            // Called synchronously when the enclosing Task is cancelled.
            // Dispatch to main actor because ElevenLabsTTSClient is @MainActor.
            Task { @MainActor [weak self] in
                self?.stopPlayback()
            }
        }
    }
}

// MARK: - Audio Delegate Bridge

/// Bridges AVAudioPlayerDelegate callbacks (audio thread) to a Swift concurrency
/// continuation (any thread). NSLock prevents double-resume if stopPlayback and the
/// natural completion race against each other.
private final class AudioPlaybackCompletionDelegate: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    private var continuation: CheckedContinuation<Void, Never>?
    private let nsLock = NSLock()

    init(continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        resumeIfPending()
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        resumeIfPending()
    }

    /// Resumes the continuation exactly once. Safe to call from any thread.
    func resumeIfPending() {
        nsLock.lock()
        let pendingContinuation = continuation
        continuation = nil
        nsLock.unlock()
        pendingContinuation?.resume()
    }
}
