//
//  ReadAloudStorage.swift
//  leanring-buddy
//
//  On-disk storage for captured ⌃⇧L read-aloud sessions: the synthesized
//  audio (16-bit PCM mono WAV) and a thin replay engine that plays the WAV
//  back and fires per-word callbacks using the stored timings so the
//  highlight overlay can animate in sync.
//
//  Files live under `~/Library/Application Support/Clicky/readaloud/{uuid}.wav`.
//  The `{uuid}` matches the owning `ChatMessage.id` so deleting the message
//  can also delete its audio asset without needing a reverse index.
//

import AVFoundation
import Foundation

enum ReadAloudStorage {

    /// Directory that holds all captured read-aloud WAV files. Created lazily.
    static var directoryURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Clicky/readaloud", isDirectory: true)
    }

    /// Resolves the full URL for a captured WAV file name inside `directoryURL`.
    static func fileURL(forWavFileName wavFileName: String) -> URL {
        directoryURL.appendingPathComponent(wavFileName)
    }

    /// Writes a mono 16-bit PCM WAV file from Float32 samples in the range
    /// [-1, 1]. Returns the file name (not the full path) so it can be
    /// serialized into `ReadAloudCaptureData`.
    @discardableResult
    static func writeWAV(
        samples: [Float],
        sampleRate: Double,
        fileBaseName: String
    ) throws -> String {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )

        let wavFileName = "\(fileBaseName).wav"
        let destinationURL = fileURL(forWavFileName: wavFileName)

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }

        let sampleCount = samples.count
        let bytesPerSample = 2
        let dataChunkSize = sampleCount * bytesPerSample
        let riffChunkSize = 36 + dataChunkSize

        var wavData = Data()
        wavData.append(contentsOf: Array("RIFF".utf8))
        wavData.appendLittleEndian(UInt32(riffChunkSize))
        wavData.append(contentsOf: Array("WAVE".utf8))

        // "fmt " sub-chunk
        wavData.append(contentsOf: Array("fmt ".utf8))
        wavData.appendLittleEndian(UInt32(16))          // PCM subchunk1Size
        wavData.appendLittleEndian(UInt16(1))           // format = PCM
        wavData.appendLittleEndian(UInt16(1))           // channels = mono
        wavData.appendLittleEndian(UInt32(sampleRate))
        wavData.appendLittleEndian(UInt32(sampleRate * Double(bytesPerSample)))  // byte rate
        wavData.appendLittleEndian(UInt16(bytesPerSample)) // block align
        wavData.appendLittleEndian(UInt16(16))          // bits per sample

        // "data" sub-chunk
        wavData.append(contentsOf: Array("data".utf8))
        wavData.appendLittleEndian(UInt32(dataChunkSize))

        // Interleaved Int16 samples, little-endian
        wavData.reserveCapacity(wavData.count + dataChunkSize)
        for sampleFloat in samples {
            let clippedFloat = max(-1.0, min(1.0, sampleFloat))
            let sampleInt16 = Int16(clippedFloat * Float(Int16.max))
            wavData.appendLittleEndian(sampleInt16)
        }

        try wavData.write(to: destinationURL)
        return wavFileName
    }

    /// Deletes the captured WAV for a given file name. Silently ignores
    /// missing files so it's safe to call as part of a message-delete flow.
    static func removeWAV(fileName: String) {
        let url = fileURL(forWavFileName: fileName)
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - ReadAloudReplayController

/// Plays a captured WAV and drives a per-word callback in sync with the
/// stored timings, so the UI can re-run the highlight animation over the
/// original screenshot (or the live screen).
///
/// Uses an `AVAudioPlayerNode.lastRenderTime`-driven poll timer (every 50ms)
/// rather than N pre-scheduled `asyncAfter` closures. Benefits:
///   - Pause/resume fall out naturally — when `player.pause()` is called,
///     `lastRenderTime` stops advancing, so the polled "current word" just
///     freezes without extra bookkeeping.
///   - Highlight self-corrects if the main thread stalls for a few frames.
///   - Far fewer main-queue wakeups during playback.
@MainActor
final class ReadAloudReplayController {

    private(set) var isPlaying: Bool = false
    private(set) var isPaused: Bool = false

    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var activeReplaySession: UUID?
    private var wordCallback: ((ReadAloudWordTiming?) -> Void)?
    private var activeWordTimings: [ReadAloudWordTiming] = []
    private var lastReportedWordIndex: Int = -1
    private var positionPollTimer: Timer?

    /// Starts playing the WAV and firing `onWordStarted` at each timing's
    /// startSeconds. Fires with `nil` when playback ends or is cancelled.
    func play(
        wavFileName: String,
        wordTimings: [ReadAloudWordTiming],
        onWordStarted: @escaping (ReadAloudWordTiming?) -> Void
    ) throws {
        stop()

        let audioFile = try AVAudioFile(forReading: ReadAloudStorage.fileURL(forWavFileName: wavFileName))
        let audioFormat = audioFile.processingFormat

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: audioFormat)

        audioEngine = engine
        playerNode = player

        let session = UUID()
        activeReplaySession = session
        wordCallback = onWordStarted
        activeWordTimings = wordTimings
        lastReportedWordIndex = -1

        player.scheduleFile(audioFile, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.activeReplaySession == session else { return }
                self.isPlaying = false
                self.isPaused = false
                self.tearDown()
                onWordStarted(nil)
            }
        }

        try engine.start()
        player.play()
        isPlaying = true
        isPaused = false
        print("▶️ [ReadAloudReplay] started — \(wordTimings.count) words, wav=\(wavFileName)")

        startPositionPollTimer(session: session)
    }

    /// Pauses audio. The highlight freezes on the current word because the
    /// underlying `lastRenderTime` stops advancing — no need to cancel any
    /// per-word timers. Resume with `resume()`.
    func pause() {
        guard isPlaying, !isPaused, let player = playerNode else { return }
        player.pause()
        isPaused = true
        print("⏸ [ReadAloudReplay] paused")
    }

    /// Resumes playback. Safe to call when not paused (no-op).
    func resume() {
        guard isPlaying, isPaused, let player = playerNode else { return }
        player.play()
        isPaused = false
        print("▶️ [ReadAloudReplay] resumed")
    }

    func stop() {
        guard activeReplaySession != nil else { return }
        activeReplaySession = nil
        stopPositionPollTimer()
        tearDown()
        let callback = wordCallback
        wordCallback = nil
        activeWordTimings = []
        lastReportedWordIndex = -1
        isPlaying = false
        isPaused = false
        callback?(nil)
        print("⏹ [ReadAloudReplay] stopped")
    }

    // MARK: - Position polling

    private func startPositionPollTimer(session: UUID) {
        stopPositionPollTimer()
        // 20Hz — smooth enough for word-level highlighting without flooding
        // the main queue. Uses a common runloop mode so scrolling the chat
        // window doesn't pause the timer.
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.pollAndReportCurrentWord(session: session)
        }
        RunLoop.main.add(timer, forMode: .common)
        positionPollTimer = timer
    }

    private func stopPositionPollTimer() {
        positionPollTimer?.invalidate()
        positionPollTimer = nil
    }

    private func pollAndReportCurrentWord(session: UUID) {
        guard activeReplaySession == session else { return }
        guard let currentPositionSeconds = currentPlaybackPositionSeconds() else { return }

        // Find the word whose [startSeconds, endSeconds) brackets the current
        // playhead. Since word timings are monotonic, a quick linear scan
        // from the last reported index is plenty fast and handles seeks.
        let matchingIndex = activeWordTimings.firstIndex { timing in
            currentPositionSeconds >= timing.startSeconds
                && currentPositionSeconds < timing.endSeconds
        } ?? activeWordTimings.lastIndex { timing in
            currentPositionSeconds >= timing.startSeconds
        } ?? -1

        if matchingIndex != lastReportedWordIndex {
            lastReportedWordIndex = matchingIndex
            if matchingIndex >= 0 && matchingIndex < activeWordTimings.count {
                wordCallback?(activeWordTimings[matchingIndex])
            }
        }
    }

    /// Translates the player node's render-clock sample time to seconds.
    /// Returns nil if the node hasn't rendered anything yet (brief startup
    /// window after `play()`).
    private func currentPlaybackPositionSeconds() -> TimeInterval? {
        guard let player = playerNode,
              let lastRenderTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: lastRenderTime),
              playerTime.sampleRate > 0 else {
            return nil
        }
        return Double(playerTime.sampleTime) / playerTime.sampleRate
    }

    private func tearDown() {
        playerNode?.stop()
        audioEngine?.stop()
        playerNode = nil
        audioEngine = nil
    }
}

// MARK: - Little-endian Data helpers

private extension Data {
    mutating func appendLittleEndian(_ value: UInt16) {
        var littleEndianValue = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndianValue) { append(contentsOf: $0) }
    }

    mutating func appendLittleEndian(_ value: UInt32) {
        var littleEndianValue = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndianValue) { append(contentsOf: $0) }
    }

    mutating func appendLittleEndian(_ value: Int16) {
        var littleEndianValue = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndianValue) { append(contentsOf: $0) }
    }
}
