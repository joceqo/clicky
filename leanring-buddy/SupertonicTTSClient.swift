//
//  SupertonicTTSClient.swift
//  leanring-buddy
//
//  On-device TTS using the Supertonic ONNX engine (66M params, ~167× realtime
//  on Apple Silicon). Models auto-download from HuggingFace on first use (~200MB).
//  Interface mirrors ElevenLabsTTSClient so CompanionManager can swap between them.
//

import AVFoundation
import Foundation
import NaturalLanguage

@MainActor
final class SupertonicTTSClient {

    /// Voice to use for synthesis. Matches upstream voice_styles/*.json filenames.
    /// Available: M1–M5 (male), F1–F5 (female).
    var selectedVoice: String {
        didSet {
            UserDefaults.standard.set(selectedVoice, forKey: "supertonicSelectedVoice")
        }
    }

    private(set) var isPlaying: Bool = false

    private var loadedEngine: SupertonicTTS?
    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?

    /// UUID used to detect when a new speakText() call cancels the current one.
    private var activePlaybackSession: UUID?

    // MARK: - Model paths

    private static let huggingFaceBaseURL = "https://huggingface.co/Supertone/supertonic-2/resolve/main"

    private static var supertonicModelDir: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Clicky/models/supertonic", isDirectory: true)
    }

    private static var onnxModelDir: URL {
        supertonicModelDir.appendingPathComponent("onnx", isDirectory: true)
    }

    private static var voiceStylesDir: URL {
        supertonicModelDir.appendingPathComponent("voice_styles", isDirectory: true)
    }

    // MARK: - Init

    init() {
        self.selectedVoice = UserDefaults.standard.string(forKey: "supertonicSelectedVoice") ?? "M1"
    }

    // MARK: - Public interface

    /// Synthesizes `text` sentence-by-sentence and begins playback as soon as the
    /// first sentence is ready. This cuts perceived latency for long responses —
    /// the user hears the first word after ~5ms instead of waiting for the full
    /// text to be synthesized. Supertonic runs at ~167× realtime, so subsequent
    /// sentences are synthesized and queued while the current one is playing.
    ///
    /// Downloads ONNX models from HuggingFace on first call (~200MB one-time).
    /// Throws on network, model-loading, or synthesis errors.
    func speakText(_ text: String) async throws {
        stopPlayback()

        let session = UUID()
        activePlaybackSession = session

        // Download models and the selected voice style file if not already on disk
        try await ensureModelsAndVoiceDownloaded(voiceId: selectedVoice)
        guard activePlaybackSession == session else { return }

        // Load the ONNX engine (cached in memory after first load)
        let tts = try loadEngineIfNeeded()
        guard activePlaybackSession == session else { return }

        let voiceStylePath = Self.voiceStylesDir.appendingPathComponent("\(selectedVoice).json").path
        let sampleRate = tts.sampleRate

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(domain: "SupertonicTTS", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Could not create audio format"])
        }

        // Split into sentences so we can start playback after the first sentence
        // is synthesized rather than waiting for the whole response.
        let sentences = splitIntoSentenceChunks(text)

        // Set up one AVAudioEngine for the full response — AVAudioPlayerNode maintains
        // an internal queue, so scheduling multiple buffers plays them gaplessly.
        let avEngine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        avEngine.attach(player)
        avEngine.connect(player, to: avEngine.mainMixerNode, format: format)
        audioEngine = avEngine
        playerNode = player

        var buffersScheduled = 0

        // Synthesize and schedule each sentence. The engine starts after the first
        // buffer is scheduled so audio begins immediately, while the rest are
        // synthesized and queued during playback.
        for (index, sentence) in sentences.enumerated() {
            guard activePlaybackSession == session else { break }

            let result = try tts.synthesize(text: sentence, lang: "en", voiceStylePath: voiceStylePath, speed: 1.05)
            let samples = result.wav
            guard !samples.isEmpty else { continue }

            let frameCount = AVAudioFrameCount(samples.count)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
                  let channelData = buffer.floatChannelData?[0] else { continue }

            buffer.frameLength = frameCount
            for i in 0..<samples.count { channelData[i] = samples[i] }

            // Start the engine right after the first sentence is synthesized
            // so the user hears audio immediately without waiting for all sentences.
            if index == 0 {
                isPlaying = true
                try avEngine.start()
                player.play()
                print("🔊 Supertonic TTS: started playback, voice \(selectedVoice), \(sentences.count) sentence(s)")
            }

            buffersScheduled += 1
            player.scheduleBuffer(buffer, completionHandler: nil)
        }

        guard buffersScheduled > 0, activePlaybackSession == session else {
            isPlaying = false
            tearDownAudioEngine()
            throw NSError(domain: "SupertonicTTS", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Supertonic returned no audio"])
        }

        // Suspend the caller until all scheduled buffers finish playing.
        // We schedule one final silent marker buffer to detect end-of-playback.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // Schedule a zero-frame sentinel buffer. AVAudioPlayerNode fires its
            // completion handler in queue order, so this fires after all audio.
            if let sentinelBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 0) {
                sentinelBuffer.frameLength = 0
                player.scheduleBuffer(sentinelBuffer) { [weak self] in
                    Task { @MainActor [weak self] in
                        guard let self else { continuation.resume(); return }
                        if self.activePlaybackSession == session {
                            self.isPlaying = false
                            self.tearDownAudioEngine()
                        }
                        continuation.resume()
                    }
                }
            } else {
                continuation.resume()
            }
        }
    }

    /// Splits text into sentence-level chunks using NLTagger's sentence boundary
    /// detection. Falls back to the full text as one chunk if tagging fails.
    private func splitIntoSentenceChunks(_ text: String) -> [String] {
        var sentences: [String] = []
        let tagger = NLTagger(tagSchemes: [.tokenType])
        tagger.string = text

        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex,
            unit: .sentence,
            scheme: .tokenType,
            options: [.omitWhitespace]
        ) { _, tokenRange in
            let sentence = String(text[tokenRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty {
                sentences.append(sentence)
            }
            return true
        }

        return sentences.isEmpty ? [text] : sentences
    }

    /// Stops any in-progress synthesis or playback immediately.
    func stopPlayback() {
        activePlaybackSession = nil
        tearDownAudioEngine()
        isPlaying = false
    }

    // MARK: - Model download

    private func ensureModelsAndVoiceDownloaded(voiceId: String) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: Self.onnxModelDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: Self.voiceStylesDir, withIntermediateDirectories: true)

        let requiredOnnxFiles = [
            "duration_predictor.onnx",
            "text_encoder.onnx",
            "vector_estimator.onnx",
            "vocoder.onnx",
            "tts.json",
            "unicode_indexer.json",
        ]

        for filename in requiredOnnxFiles {
            let destinationURL = Self.onnxModelDir.appendingPathComponent(filename)
            if !fm.fileExists(atPath: destinationURL.path) {
                print("⬇️ Supertonic: downloading \(filename)...")
                try await downloadFileFromHuggingFace(remotePath: "onnx/\(filename)", to: destinationURL)
            }
        }

        let voiceStyleDestinationURL = Self.voiceStylesDir.appendingPathComponent("\(voiceId).json")
        if !fm.fileExists(atPath: voiceStyleDestinationURL.path) {
            print("⬇️ Supertonic: downloading voice style \(voiceId)...")
            try await downloadFileFromHuggingFace(remotePath: "voice_styles/\(voiceId).json",
                                                   to: voiceStyleDestinationURL)
        }
    }

    private func downloadFileFromHuggingFace(remotePath: String, to destinationURL: URL) async throws {
        guard let downloadURL = URL(string: "\(Self.huggingFaceBaseURL)/\(remotePath)") else {
            throw NSError(domain: "SupertonicTTS", code: -4,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid HuggingFace URL for \(remotePath)"])
        }

        let (tempURL, response) = try await URLSession.shared.download(from: downloadURL)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw NSError(domain: "SupertonicTTS", code: -5,
                          userInfo: [NSLocalizedDescriptionKey: "Download failed for \(remotePath)"])
        }

        try FileManager.default.moveItem(at: tempURL, to: destinationURL)
    }

    // MARK: - Engine loading

    private func loadEngineIfNeeded() throws -> SupertonicTTS {
        if let loadedEngine { return loadedEngine }

        print("🔧 Supertonic: loading ONNX engine...")
        let engine = try supertonicLoadEngine(onnxDir: Self.onnxModelDir.path)
        loadedEngine = engine
        print("✅ Supertonic: engine ready")
        return engine
    }

    // MARK: - Audio teardown

    private func tearDownAudioEngine() {
        playerNode?.stop()
        audioEngine?.stop()
        playerNode = nil
        audioEngine = nil
    }
}
