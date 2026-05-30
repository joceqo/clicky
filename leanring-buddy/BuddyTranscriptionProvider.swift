//
//  BuddyTranscriptionProvider.swift
//  leanring-buddy
//
//  Shared protocol surface for voice transcription backends.
//

import AVFoundation
import Foundation

protocol BuddyStreamingTranscriptionSession: AnyObject {
    var finalTranscriptFallbackDelaySeconds: TimeInterval { get }
    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer)
    func requestFinalTranscript()
    func cancel()
}

protocol BuddyTranscriptionProvider {
    var displayName: String { get }
    var requiresSpeechRecognitionPermission: Bool { get }
    var isConfigured: Bool { get }
    var unavailableExplanation: String? { get }

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession
}

enum BuddyTranscriptionProviderFactory {

    /// Resolves the active transcription provider from the shared `ProviderStore`'s
    /// STT slot (one key reused across slots; migrated once from the legacy keys).
    static func makeDefaultProvider() -> any BuddyTranscriptionProvider {
        let store = ProviderStoreFactory.load()
        let settings = store.stt.legacySettings(
            provider: store.provider(for: store.stt.providerID)
        )
        let provider = STTProviderFactory.makeProvider(settings: settings)
        print("🎙️ Transcription: using \(provider.displayName)")
        return provider
    }
}
