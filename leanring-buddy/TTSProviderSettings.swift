//
//  TTSProviderSettings.swift
//  leanring-buddy
//
//  TTS provider configuration, persisted to UserDefaults.
//  One enum value covers all OpenAI-compatible servers (Voicebox local,
//  OpenAI TTS, Voxtral, and any future endpoint) — users configure
//  baseURL + model + voice + optional API key in Settings.
//

import AppKit
import AVFoundation
import Foundation

// MARK: - Provider type

enum TTSProviderType: String, Codable, CaseIterable, Identifiable {
    /// ElevenLabs via Cloudflare Worker proxy (default; key never leaves server)
    case elevenLabs = "elevenlabs"
    /// Any OpenAI-compatible /v1/audio/speech endpoint (Voicebox, OpenAI, Voxtral, …)
    case openAICompat = "openai_compat"
    /// Apple NSSpeechSynthesizer — no network, always available, low quality fallback
    case system = "system"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .elevenLabs:   return "ElevenLabs"
        case .openAICompat: return "OpenAI-compatible"
        case .system:       return "System (Apple)"
        }
    }
}

// MARK: - Settings

struct TTSProviderSettings: Codable {
    var providerType: TTSProviderType = .elevenLabs

    // OpenAI-compat settings — apply to Voicebox, OpenAI TTS, Voxtral, etc.
    var openAICompatBaseURL: String = "http://127.0.0.1:8880"
    var openAICompatAPIKey: String  = ""
    var openAICompatModel: String   = "kokoro"
    var openAICompatVoice: String   = "af_heart"
    var openAICompatSpeed: Double   = 1.0
}

// MARK: - Named presets

extension TTSProviderSettings {
    /// Local Voicebox server (default port 8880, kokoro model)
    static var voicebox: TTSProviderSettings {
        TTSProviderSettings(
            providerType: .openAICompat,
            openAICompatBaseURL: "http://127.0.0.1:8880",
            openAICompatAPIKey: "",
            openAICompatModel: "kokoro",
            openAICompatVoice: "af_heart",
            openAICompatSpeed: 1.0
        )
    }

    /// OpenAI TTS (requires API key)
    static func openAI(apiKey: String, voice: String = "nova") -> TTSProviderSettings {
        TTSProviderSettings(
            providerType: .openAICompat,
            openAICompatBaseURL: "https://api.openai.com",
            openAICompatAPIKey: apiKey,
            openAICompatModel: "tts-1",
            openAICompatVoice: voice,
            openAICompatSpeed: 1.0
        )
    }

    /// Mistral TTS (requires API key). NOTE: this is Mistral's text-to-speech,
    /// NOT Voxtral — Voxtral is Mistral's speech-to-text model (see STTProviderSettings).
    // Mistral exposes 30 voices via GET /v1/audio/voices (must request the full
    // catalog — paginate with `limit`, not just the default first page of 10).
    // 6 are French: fr_marie_{neutral,happy,sad,angry,excited,curious}.
    static func mistral(apiKey: String, voice: String = "fr_marie_neutral") -> TTSProviderSettings {
        TTSProviderSettings(
            providerType: .openAICompat,
            openAICompatBaseURL: "https://api.mistral.ai",
            openAICompatAPIKey: apiKey,
            openAICompatModel: "voxtral-mini-tts-2603",
            openAICompatVoice: voice,
            openAICompatSpeed: 1.2
        )
    }

    /// Arbitrary OpenAI-compat TTS server
    static func custom(
        baseURL: String,
        model: String,
        voice: String,
        apiKey: String = "",
        speed: Double = 1.0
    ) -> TTSProviderSettings {
        TTSProviderSettings(
            providerType: .openAICompat,
            openAICompatBaseURL: baseURL,
            openAICompatAPIKey: apiKey,
            openAICompatModel: model,
            openAICompatVoice: voice,
            openAICompatSpeed: speed
        )
    }
}

// MARK: - Factory

enum TTSProviderFactory {

    private static let userDefaultsKey = "ttsProviderSettings"

    /// Creates the TTSClient described by `settings`.
    /// - Parameter elevenLabsProxyURL: The Cloudflare Worker `/tts` URL, used when
    ///   `providerType == .elevenLabs`. Pass `CompanionManager.workerBaseURL + "/tts"`.
    static func makeClient(
        settings: TTSProviderSettings,
        elevenLabsProxyURL: String
    ) -> any TTSClient {
        switch settings.providerType {
        case .elevenLabs:
            return ElevenLabsTTSClient(proxyURL: elevenLabsProxyURL)

        case .openAICompat:
            return OpenAICompatibleTTSClient(
                baseURL: settings.openAICompatBaseURL,
                model: settings.openAICompatModel,
                voice: settings.openAICompatVoice,
                apiKey: settings.openAICompatAPIKey.isEmpty ? nil : settings.openAICompatAPIKey,
                speed: settings.openAICompatSpeed
            )

        case .system:
            return SystemTTSClient()
        }
    }

    static func loadSettings() -> TTSProviderSettings {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              var settings = try? JSONDecoder().decode(TTSProviderSettings.self, from: data) else {
            return TTSProviderSettings()
        }
        // Migrate the invalid placeholder model shipped in an earlier build so
        // users don't have to re-pick the Mistral preset to fix the 400.
        if settings.openAICompatModel == "mistral-tts-latest" {
            settings.openAICompatModel = "voxtral-mini-tts-2603"
        }
        return settings
    }

    static func saveSettings(_ settings: TTSProviderSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: userDefaultsKey)
    }
}

// MARK: - System TTS client (Apple fallback)

/// Uses NSSpeechSynthesizer for offline, no-config TTS. Low audio quality
/// but always available — useful as an emergency fallback if all network
/// TTS providers are unreachable.
@MainActor
final class SystemTTSClient: TTSClient {
    private let synthesizer = NSSpeechSynthesizer()
    private var speaking = false

    var isPlaying: Bool { speaking }

    func stopPlayback() {
        synthesizer.stopSpeaking()
        speaking = false
    }

    func speakText(_ text: String) async throws {
        try Task.checkCancellation()
        speaking = true
        synthesizer.startSpeaking(text)

        // NSSpeechSynthesizer has no async delegate, so poll at 50ms intervals.
        while synthesizer.isSpeaking {
            try await Task.sleep(nanoseconds: 50_000_000)
            if Task.isCancelled {
                synthesizer.stopSpeaking()
                speaking = false
                throw CancellationError()
            }
        }
        speaking = false
    }
}
