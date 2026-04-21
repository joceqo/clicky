//
//  KokoroTTSClient.swift
//  leanring-buddy
//
//  On-device TTS using the Kokoro-82M MLX model via the mlalma/kokoro-ios
//  Swift package. Runs entirely on Apple Silicon (MLX → GPU/ANE). Downloads
//  the model (.safetensors, ~330MB) and voice embedding bundle (voices.npz,
//  ~10MB) from HuggingFace / GitHub on first use.
//
//  Unlike ElevenLabs and Supertonic, Kokoro exposes per-word timestamps via

//  MisakiSwift's MToken struct. This is what powers the read-aloud
//  highlight overlay — we schedule a callback to fire at each token's
//  start_ts so the overlay can move to the next word on cue.
//
//  Public interface mirrors SupertonicTTSClient so CompanionManager can
//  route between Kokoro and the other providers transparently. A new
//  speakTextWithWordTimings(_:onWordStarted:) entry point is added for the
//  read-aloud pipeline that needs per-word callbacks.
//

import AVFoundation
import Foundation
import KokoroSwift
import MLX
import MLXUtilsLibrary
import NaturalLanguage
import os

/// os_log Logger for Kokoro TTS. Surfaces in Console.app / `log show` even
/// after the app crashes, unlike `print` which only lives in Xcode's console.
/// Subsystem doesn't have to match the real bundle ID — it's just the filter
/// identifier, so we use a stable project-scoped string.
private let kokoroLogger = Logger(subsystem: "com.clicky.leanring-buddy", category: "Kokoro")

/// A single word's playback timing, in seconds relative to the start of the
/// overall utterance (summed across sentence chunks). Exposed to the caller
/// so it can drive a follow-along highlight overlay without having to
/// import MisakiSwift's MToken type.
public struct KokoroWordTiming: Sendable {
    public let text: String
    /// Character offset in the original text passed to `speakText`. Callers
    /// use this to find the word's screen bounding box via `ExtractedWordInfo`.
    public let characterRange: NSRange
    public let startSeconds: TimeInterval
    public let endSeconds: TimeInterval
    /// 0-based index of this word in the full playback sequence.
    public let sequenceIndex: Int
}

@MainActor
final class KokoroTTSClient {

    /// Voice identifier. Default "af_heart" is the recommended Kokoro voice.
    /// Supported voices are whatever keys live in voices.npz (28+ options).
    /// The voice name's first letter picks the language: "a" = US English,
    /// any other prefix = GB English. This matches the convention in
    /// KokoroTestApp.
    var selectedVoice: String {
        didSet {
            UserDefaults.standard.set(selectedVoice, forKey: "kokoroSelectedVoice")
        }
    }

    private(set) var isPlaying: Bool = false

    private var loadedEngine: KokoroTTS?
    private var loadedVoices: [String: MLXArray] = [:]

    /// Long-lived, detached task that downloads the model + voices. Shared
    /// across all speakText calls so repeated ⌃⇧L taps don't cancel and
    /// restart the 330MB download each time. Survives speak cancellation
    /// because it's a `Task.detached` — parent-Task cancellation can't reach
    /// it. Cleared back to nil only if the download fails, so a later press
    /// can retry.
    private var sharedDownloadTask: Task<Void, Error>?

    /// Tracks the currently-running MLX inference (if any) so that a newly
    /// started speakText can await its completion before launching its own
    /// detached inference. Without this gate, rapid ⌃⇧L toggles spawn
    /// concurrent MLX inferences that each pin a copy of the 82M-param model
    /// on the GPU heap — the pile-up that caused the 17GB memory blow-up.
    /// The UUID token lets us clear the slot only when the same task we
    /// installed is the one finishing, avoiding clobbering a newer inflight
    /// task.
    private var inflightSynthesisTask: Task<([Float], [MToken]?), Error>?
    private var inflightSynthesisToken: UUID?

    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?

    /// Session ID so late-arriving timer callbacks from a cancelled utterance
    /// can be ignored. Every fresh speakText call rotates this.
    private var activePlaybackSession: UUID?

    /// Fired on the main actor per word during the current playback. Captured
    /// so the stopPlayback path can suppress any still-in-flight callbacks.
    private var currentWordTimingCallback: ((KokoroWordTiming?) -> Void)?

    // MARK: - Model / voices paths

    /// mlx-community's bf16 Kokoro weights — the ones expected by
    /// `mlalma/kokoro-ios`'s WeightLoader.
    /// `nonisolated` so the detached download task can read it without
    /// hopping to the MainActor.
    nonisolated private static let modelDownloadURL =
        "https://huggingface.co/mlx-community/Kokoro-82M-bf16/resolve/main/kokoro-v1_0.safetensors"


    nonisolated private static var kokoroModelDir: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Clicky/models/kokoro", isDirectory: true)
    }

    nonisolated private static var safetensorsPath: URL {
        kokoroModelDir.appendingPathComponent("kokoro-v1_0.safetensors")
    }

    nonisolated private static var voicesPath: URL {
        kokoroModelDir.appendingPathComponent("voices.npz")
    }

    /// Kokoro's fixed output sample rate. Declared locally so this file
    /// doesn't have to reach into KokoroSwift's internal Constants.
    private static let sampleRate: Double = 24_000

    /// Kokoro's hard phoneme-token limit per inference. Sentences longer than
    /// this (very rare — a single sentence of ~2–3 paragraphs of dense text)
    /// are skipped with a log rather than crashing. Phoneme count ~= 0.8 ×
    /// character count for English, so ~400 chars is a safe ceiling.
    private static let maxCharactersPerSentence = 400

    // MARK: - Init

    init() {
        self.selectedVoice = UserDefaults.standard.string(forKey: "kokoroSelectedVoice") ?? "af_heart"
    }

    // MARK: - Public interface

    /// All data captured during a single speakTextWithWordTimings call:
    /// concatenated audio samples (mono float32 at `sampleRate`) and per-word
    /// timings. The caller can persist this to disk so a later ⏵ Replay can
    /// reproduce the playback + highlight animation frame-for-frame.
    struct CaptureResult: Sendable {
        let audioSamples: [Float]
        let sampleRate: Double
        let wordTimings: [KokoroWordTiming]
    }

    /// Speaks `text` end-to-end using the selected voice. No word callback —
    /// used for plain chat-style TTS where the highlight overlay isn't needed.
    /// The captured audio is still produced and returned in case a caller
    /// wants to persist it, but the result can be freely discarded.
    @discardableResult
    func speakText(_ text: String) async throws -> CaptureResult {
        try await speakTextWithWordTimings(text, onWordStarted: nil)
    }

    /// Speaks `text` and fires `onWordStarted` at the moment each word begins
    /// playing. Passes `nil` once playback finishes or is cancelled so the
    /// caller can clear its highlight UI. The callback is invoked on the main
    /// actor (same as this class).
    ///
    /// Behavior:
    ///   - Splits text into sentences (NLTagger) to stay under Kokoro's
    ///     ~510-token inference limit.
    ///   - Synthesizes sentence-by-sentence; starts playback after the first
    ///     sentence is ready so the user hears audio quickly on long text.
    ///   - Builds a cumulative timeline of MToken start/end timestamps across
    ///     all sentences and schedules main-actor callbacks at each token's
    ///     absolute start offset.
    ///   - Downloads the ~330MB model file and ~10MB voices file on first
    ///     call (cached in Application Support).
    ///
    /// Throws on network, model-loading, or synthesis errors.
    func speakTextWithWordTimings(
        _ text: String,
        onWordStarted: ((KokoroWordTiming?) -> Void)?
    ) async throws -> CaptureResult {
        stopPlayback()

        let session = UUID()
        activePlaybackSession = session
        currentWordTimingCallback = onWordStarted

        // Accumulates across sentence synthesis so the caller gets a single
        // WAV-ready Float array and the full list of word timings at the end.
        var capturedSamples: [Float] = []
        var capturedTimings: [KokoroWordTiming] = []

        try await ensureModelAndVoicesDownloaded()
        guard activePlaybackSession == session else {
            return CaptureResult(audioSamples: [], sampleRate: Self.sampleRate, wordTimings: [])
        }

        let engine = try loadEngineIfNeeded()
        guard activePlaybackSession == session else {
            return CaptureResult(audioSamples: [], sampleRate: Self.sampleRate, wordTimings: [])
        }

        let voiceEmbedding = try resolveVoiceEmbedding(voiceName: selectedVoice)
        let language: Language = selectedVoice.first == "a" ? .enUS : .enGB

        guard let audioFormat = AVAudioFormat(
            standardFormatWithSampleRate: Self.sampleRate,
            channels: 1
        ) else {
            throw KokoroClientError.audioFormatCreationFailed
        }

        let sentenceChunks = splitIntoSentenceChunks(text)
        guard !sentenceChunks.isEmpty else {
            return CaptureResult(audioSamples: [], sampleRate: Self.sampleRate, wordTimings: [])
        }

        let avEngine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        avEngine.attach(player)
        avEngine.connect(player, to: avEngine.mainMixerNode, format: audioFormat)
        audioEngine = avEngine
        playerNode = player

        // Wall-clock time at which the first buffer begins playing — used to
        // convert per-token start_ts values (which are per-sentence) into
        // absolute delays from "now".
        var playbackStartDate: Date?
        var cumulativeChunkStartSeconds: TimeInterval = 0
        var totalWordSequenceIndex = 0
        var buffersScheduled = 0

        for sentenceChunk in sentenceChunks {
            guard activePlaybackSession == session else { break }

            // Kokoro errors out on very long sentences. Skip rather than crash.
            let sentenceText = sentenceChunk.text
            if sentenceText.count > Self.maxCharactersPerSentence {
                kokoroLogger.notice("skipping sentence longer than \(Self.maxCharactersPerSentence, privacy: .public) chars")
                continue
            }

            let synthesisStart = Date()
            let synthesized: ([Float], [MToken]?)
            do {
                // Kokoro synthesis is CPU-heavy (MLX inference) and previously
                // blocked the main thread for 0.5-3s per sentence, which
                // starved the asyncAfter callbacks and made the highlight
                // land seconds late. Hop to a background queue so main stays
                // responsive and the word-timing timers fire on time.
                synthesized = try await runSerializedSynthesis(
                    payload: KokoroSynthesisPayload(
                        engine: engine,
                        voice: voiceEmbedding,
                        language: language,
                        text: sentenceText
                    )
                )
            } catch {
                kokoroLogger.error("synthesis error on sentence \(sentenceChunk.index, privacy: .public): \(String(describing: error), privacy: .public)")
                continue
            }
            let synthesisDurationSeconds = Date().timeIntervalSince(synthesisStart)
            kokoroLogger.info("sentence \(sentenceChunk.index, privacy: .public) synth in \(String(format: "%.2f", synthesisDurationSeconds), privacy: .public)s, \(synthesized.0.count, privacy: .public) samples")

            let sampleBuffer = synthesized.0
            let tokenArray = synthesized.1
            guard !sampleBuffer.isEmpty else { continue }

            guard activePlaybackSession == session else { break }

            guard let pcmBuffer = makePCMBuffer(samples: sampleBuffer, format: audioFormat) else { continue }
            let sentenceDurationSeconds = Double(sampleBuffer.count) / Self.sampleRate

            // Start the engine as soon as we have the first buffer. Anchor
            // playbackStartDate the moment playback begins so every subsequent
            // token delay is computed from the same origin.
            if playbackStartDate == nil {
                isPlaying = true
                try avEngine.start()
                player.play()
                playbackStartDate = Date()
                kokoroLogger.info("started playback, voice \(self.selectedVoice, privacy: .public), \(sentenceChunks.count, privacy: .public) sentence(s)")
            }

            player.scheduleBuffer(pcmBuffer, completionHandler: nil)
            buffersScheduled += 1
            capturedSamples.append(contentsOf: sampleBuffer)

            if let tokenArray, let startDate = playbackStartDate {
                let sentenceTimings = scheduleWordTimingCallbacks(
                    tokens: tokenArray,
                    sentenceText: sentenceText,
                    originalTextSentenceRange: sentenceChunk.originalRange,
                    chunkStartSeconds: cumulativeChunkStartSeconds,
                    playbackStartDate: startDate,
                    sequenceIndexStart: totalWordSequenceIndex,
                    session: session
                )
                capturedTimings.append(contentsOf: sentenceTimings)
                totalWordSequenceIndex += tokenArray.count
            }

            cumulativeChunkStartSeconds += sentenceDurationSeconds
        }

        guard buffersScheduled > 0, activePlaybackSession == session else {
            isPlaying = false
            tearDownAudioEngine()
            MLX.GPU.clearCache()
            throw KokoroClientError.noAudioGenerated
        }

        // Suspend the caller until all scheduled buffers finish playing.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if let sentinelBuffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: 0) {
                sentinelBuffer.frameLength = 0
                player.scheduleBuffer(sentinelBuffer) { [weak self] in
                    Task { @MainActor [weak self] in
                        guard let self else { continuation.resume(); return }
                        if self.activePlaybackSession == session {
                            self.isPlaying = false
                            self.tearDownAudioEngine()
                            // Reclaim the MLX GPU-buffer cache built up during
                            // this utterance. Without this, the cache grows on
                            // every read-aloud and the process RSS balloons
                            // into the tens of GB over a session.
                            MLX.GPU.clearCache()
                            // Fire a final "nil" word so the overlay clears.
                            self.currentWordTimingCallback?(nil)
                            self.currentWordTimingCallback = nil
                        }
                        continuation.resume()
                    }
                }
            } else {
                continuation.resume()
            }
        }

        return CaptureResult(
            audioSamples: capturedSamples,
            sampleRate: Self.sampleRate,
            wordTimings: capturedTimings
        )
    }

    /// Stops any in-progress synthesis or playback immediately and clears any
    /// pending word-timing callbacks.
    ///
    /// Note: an MLX inference already in flight can't be cancelled mid-call —
    /// it will complete on its detached task, but its result is discarded via
    /// the session-UUID guard in `speakTextWithWordTimings`. We also reclaim
    /// the MLX buffer cache here so rapid start/stop cycles don't pile up
    /// cached GPU memory.
    func stopPlayback() {
        activePlaybackSession = nil
        tearDownAudioEngine()
        isPlaying = false
        MLX.GPU.clearCache()
        if let callback = currentWordTimingCallback {
            callback(nil)
        }
        currentWordTimingCallback = nil
    }

    // MARK: - Sentence chunking

    private struct SentenceChunk {
        let index: Int
        let text: String
        /// Character range (NSRange) of this sentence in the original full text.
        /// Used to translate per-sentence token ranges back to absolute
        /// positions in the caller's text so the highlight overlay can
        /// cross-reference `ExtractedWordInfo.range`.
        let originalRange: NSRange
    }

    /// Splits input text into sentence-level chunks using NLTagger. Returns
    /// trimmed sentence text with its NSRange inside the original string.
    private func splitIntoSentenceChunks(_ text: String) -> [SentenceChunk] {
        var chunks: [SentenceChunk] = []
        let tagger = NLTagger(tagSchemes: [.tokenType])
        tagger.string = text

        var currentIndex = 0
        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex,
            unit: .sentence,
            scheme: .tokenType,
            options: [.omitWhitespace]
        ) { _, tokenRange in
            let sentenceText = String(text[tokenRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sentenceText.isEmpty else { return true }
            let nsRange = NSRange(tokenRange, in: text)
            chunks.append(SentenceChunk(index: currentIndex, text: sentenceText, originalRange: nsRange))
            currentIndex += 1
            return true
        }

        if chunks.isEmpty {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                chunks.append(SentenceChunk(
                    index: 0,
                    text: trimmed,
                    originalRange: NSRange(location: 0, length: (text as NSString).length)
                ))
            }
        }

        return chunks
    }

    // MARK: - Word-timing scheduling

    /// Schedules a main-actor callback to fire at each MToken's absolute start
    /// time (measured from when the first buffer began playing). Checks the
    /// session UUID on fire so that callbacks from a cancelled utterance are
    /// silently dropped. Returns the ordered list of KokoroWordTimings it
    /// created so the caller can accumulate them into the CaptureResult.
    private func scheduleWordTimingCallbacks(
        tokens: [MToken],
        sentenceText: String,
        originalTextSentenceRange: NSRange,
        chunkStartSeconds: TimeInterval,
        playbackStartDate: Date,
        sequenceIndexStart: Int,
        session: UUID
    ) -> [KokoroWordTiming] {
        let sentenceNSString = sentenceText as NSString
        var emittedTimings: [KokoroWordTiming] = []

        for (tokenOffset, token) in tokens.enumerated() {
            guard let startTs = token.start_ts, let endTs = token.end_ts else { continue }

            // MToken.tokenRange is in terms of sentenceText. Convert to the
            // corresponding NSRange within the original full text by adding
            // the sentence's offset in the original text.
            let sentenceLocalNSRange = NSRange(token.tokenRange, in: sentenceText)
            let absoluteLocation = originalTextSentenceRange.location + sentenceLocalNSRange.location
            let absoluteNSRange = NSRange(location: absoluteLocation, length: sentenceLocalNSRange.length)

            // Guard against bogus ranges if tokenRange drifted somehow.
            guard sentenceLocalNSRange.location + sentenceLocalNSRange.length <= sentenceNSString.length else {
                continue
            }

            let absoluteStartSeconds = chunkStartSeconds + startTs
            let absoluteEndSeconds = chunkStartSeconds + endTs
            let sequenceIndex = sequenceIndexStart + tokenOffset

            let wordTiming = KokoroWordTiming(
                text: token.text,
                characterRange: absoluteNSRange,
                startSeconds: absoluteStartSeconds,
                endSeconds: absoluteEndSeconds,
                sequenceIndex: sequenceIndex
            )
            emittedTimings.append(wordTiming)

            let delaySeconds = max(
                0,
                playbackStartDate.addingTimeInterval(absoluteStartSeconds).timeIntervalSinceNow
            )

            DispatchQueue.main.asyncAfter(deadline: .now() + delaySeconds) { [weak self] in
                guard let self else { return }
                guard self.activePlaybackSession == session else { return }
                self.currentWordTimingCallback?(wordTiming)
            }
        }

        return emittedTimings
    }

    // MARK: - Model / voices download

    /// Ensures the model weights + voices are present on disk. Safe to call
    /// repeatedly from overlapping speak requests: the actual download runs
    /// in a single detached task that all callers await. Cancelling the caller
    /// (e.g. user taps ⌃⇧L a second time during the download) does not
    /// cancel the underlying URLSession download — it keeps running so the
    /// next press can hit a ready cache.
    ///
    /// Voices are bundled inside the app (Resources/voices.npz), so we
    /// copy rather than download them on first use — no runtime dep on a
    /// third-party GitHub repo. Only the 330MB `.safetensors` model still
    /// needs downloading from HuggingFace.
    private func ensureModelAndVoicesDownloaded() async throws {
        if let sharedDownloadTask {
            try await sharedDownloadTask.value
            return
        }

        let freshTask: Task<Void, Error> = Task.detached {
            let fileManager = FileManager.default
            try fileManager.createDirectory(
                at: Self.kokoroModelDir,
                withIntermediateDirectories: true
            )

            if !fileManager.fileExists(atPath: Self.safetensorsPath.path) {
                kokoroLogger.info("downloading model weights (~330MB) — one-time cost on first use")
                try await Self.downloadFile(from: Self.modelDownloadURL, to: Self.safetensorsPath)
                kokoroLogger.info("model weights downloaded")
            }

            if !fileManager.fileExists(atPath: Self.voicesPath.path) {
                try Self.copyBundledVoicesToCache()
            }
        }
        sharedDownloadTask = freshTask

        do {
            try await freshTask.value
        } catch is CancellationError {
            // The *caller* was cancelled — the detached task keeps running.
            // Leave sharedDownloadTask in place so the next press picks up the
            // in-flight download instead of starting another one.
            throw CancellationError()
        } catch {
            // Real failure inside the detached task (e.g. network error).
            // Clear the slot so a later press can retry with a fresh task.
            sharedDownloadTask = nil
            throw error
        }
    }

    /// Holds everything a background synthesis pass needs so it can be
    /// shipped across an actor boundary without the compiler tripping on
    /// non-Sendable MLX types. `@unchecked Sendable` is safe here because
    /// the payload is consumed exactly once from a freshly-spawned detached
    /// task — no concurrent access.
    private struct KokoroSynthesisPayload: @unchecked Sendable {
        let engine: KokoroTTS
        let voice: MLXArray
        let language: Language
        let text: String
    }

    /// Runs `engine.generateAudio` on a background queue so the main thread
    /// stays free to fire the per-word `asyncAfter` highlight callbacks on
    /// schedule.
    ///
    /// Serializes inferences through `inflightSynthesisTask`: if a previous
    /// speakText was cancelled mid-synthesis, the detached MLX call is still
    /// on the GPU. We await its completion (discarding the result) before
    /// launching a fresh inference, so at most ONE MLX inference runs at a
    /// time. Without this, rapid ⌃⇧L toggles used to stack concurrent MLX
    /// runs and pin many multi-GB tensor allocations on the unified heap.
    private func runSerializedSynthesis(
        payload: KokoroSynthesisPayload
    ) async throws -> ([Float], [MToken]?) {
        if let previous = inflightSynthesisTask {
            // The previous speak session is gone, but its MLX call may still be
            // on the GPU. Let it finish and drop whatever it produced.
            _ = try? await previous.value
        }

        let freshTask: Task<([Float], [MToken]?), Error> = Task.detached(priority: .userInitiated) {
            try payload.engine.generateAudio(
                voice: payload.voice,
                language: payload.language,
                text: payload.text,
                speed: 1.0
            )
        }
        let token = UUID()
        inflightSynthesisTask = freshTask
        inflightSynthesisToken = token

        // Clear the slot from a sidecar task that awaits the *detached* task's
        // actual completion, not the caller's await. If the caller is cancelled
        // its own `try await freshTask.value` throws immediately, but the MLX
        // inference keeps running on the GPU. Clearing the slot in a defer
        // would then let the next caller spawn a SECOND concurrent inference —
        // precisely the leak we're trying to prevent.
        Task { @MainActor [weak self] in
            _ = try? await freshTask.value
            guard let self else { return }
            if self.inflightSynthesisToken == token {
                self.inflightSynthesisTask = nil
                self.inflightSynthesisToken = nil
            }
        }

        return try await freshTask.value
    }

    /// Copies the bundled Resources/voices.npz into the on-disk cache so
    /// KokoroTTS's NpyzReader can read it from a plain file path. Shipping
    /// the voices inside the app removes a runtime network dep on GitHub
    /// and lets read-aloud work offline after the one-time model download.
    nonisolated private static func copyBundledVoicesToCache() throws {
        guard let bundledVoicesURL = Bundle.main.url(forResource: "voices", withExtension: "npz") else {
            throw KokoroClientError.voicesLoadFailed
        }
        try FileManager.default.copyItem(at: bundledVoicesURL, to: Self.voicesPath)
        kokoroLogger.info("copied bundled voice embeddings to cache")
    }

    /// Plain async download helper. Static so it can be called from inside a
    /// `Task.detached` without requiring the (MainActor-isolated) enclosing
    /// class's context — the detached task doesn't inherit MainActor, and
    /// URLSession.download is non-actor-isolated.
    nonisolated private static func downloadFile(from urlString: String, to destinationURL: URL) async throws {
        guard let sourceURL = URL(string: urlString) else {
            throw KokoroClientError.invalidDownloadURL(urlString)
        }

        let (temporaryURL, response) = try await URLSession.shared.download(from: sourceURL)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw KokoroClientError.downloadFailed(urlString)
        }

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
    }

    // MARK: - Engine loading

    private func loadEngineIfNeeded() throws -> KokoroTTS {
        if let loadedEngine { return loadedEngine }

        kokoroLogger.info("loading MLX engine...")
        let engine = KokoroTTS(modelPath: Self.safetensorsPath, g2p: .misaki)
        loadedEngine = engine

        if loadedVoices.isEmpty {
            loadedVoices = NpyzReader.read(fileFromPath: Self.voicesPath) ?? [:]
            if loadedVoices.isEmpty {
                throw KokoroClientError.voicesLoadFailed
            }
            kokoroLogger.info("loaded \(self.loadedVoices.count, privacy: .public) voices")
        }

        kokoroLogger.info("engine ready")
        return engine
    }

    private func resolveVoiceEmbedding(voiceName: String) throws -> MLXArray {
        // Voices in voices.npz are keyed as "{name}.npy" per the NPZ convention
        // that bundles serialized npy files. Try the dotted form first, then
        // fall back to the bare name in case the bundle changes format later.
        if let voiceEmbedding = loadedVoices["\(voiceName).npy"] {
            return voiceEmbedding
        }
        if let voiceEmbedding = loadedVoices[voiceName] {
            return voiceEmbedding
        }
        throw KokoroClientError.voiceNotFound(voiceName)
    }

    // MARK: - Audio helpers

    private func makePCMBuffer(samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frameCount = AVAudioFrameCount(samples.count)
        guard frameCount > 0,
              let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channelData = pcmBuffer.floatChannelData?[0] else {
            return nil
        }
        pcmBuffer.frameLength = frameCount
        samples.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            channelData.update(from: baseAddress, count: samples.count)
        }
        return pcmBuffer
    }

    private func tearDownAudioEngine() {
        playerNode?.stop()
        audioEngine?.stop()
        playerNode = nil
        audioEngine = nil
    }

    // MARK: - Errors

    enum KokoroClientError: Error, LocalizedError {
        case audioFormatCreationFailed
        case noAudioGenerated
        case voicesLoadFailed
        case voiceNotFound(String)
        case invalidDownloadURL(String)
        case downloadFailed(String)

        var errorDescription: String? {
            switch self {
            case .audioFormatCreationFailed:
                return "Failed to create Kokoro audio format"
            case .noAudioGenerated:
                return "Kokoro returned no audio samples"
            case .voicesLoadFailed:
                return "Failed to load Kokoro voices.npz"
            case .voiceNotFound(let name):
                return "Kokoro voice not found: \(name)"
            case .invalidDownloadURL(let urlString):
                return "Invalid Kokoro download URL: \(urlString)"
            case .downloadFailed(let urlString):
                return "Kokoro download failed: \(urlString)"
            }
        }
    }
}
