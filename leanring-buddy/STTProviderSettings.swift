//
//  STTProviderSettings.swift
//  leanring-buddy
//
//  STT (speech-to-text) provider configuration, persisted to UserDefaults.
//  Mirrors TTSProviderSettings / BrainProviderSettings: one enum value
//  (`openAICompat`) covers every OpenAI-compatible /v1/audio/transcriptions
//  endpoint (Mistral Voxtral, OpenAI Whisper, local Voicebox Whisper,
//  LM Studio, …) — users configure baseURL + model + optional API key.
//
//  NOTE: STT needs only URL + key + model. There is NO "voice" for STT —
//  voices are a TTS concept.
//

import Foundation

// MARK: - Provider type

enum STTProviderType: String, Codable, CaseIterable, Identifiable {
    /// AssemblyAI streaming websocket transcription via the Cloudflare Worker proxy.
    case assemblyAI = "assemblyai"
    /// Any OpenAI-compatible /v1/audio/transcriptions endpoint
    /// (Voxtral, OpenAI Whisper, Voicebox, LM Studio, custom server).
    case openAICompat = "openai_compat"
    /// Apple Speech framework — on-device, no network, always available.
    case appleSpeech = "apple"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .assemblyAI:   return "AssemblyAI (streaming)"
        case .openAICompat: return "OpenAI-compatible (Voxtral / Whisper / Voicebox / LM Studio)"
        case .appleSpeech:  return "Apple Speech (on-device)"
        }
    }
}

// MARK: - Settings

struct STTProviderSettings: Codable {
    var providerType: STTProviderType = .assemblyAI

    // OpenAI-compat settings — apply to Voxtral, OpenAI Whisper, Voicebox, LM Studio, etc.
    var openAICompatBaseURL: String = "https://api.openai.com"
    var openAICompatAPIKey: String  = ""
    var openAICompatModel: String   = "whisper-1"
}

// MARK: - Named presets

extension STTProviderSettings {
    /// Mistral Voxtral (requires API key).
    static func voxtral(apiKey: String = "") -> STTProviderSettings {
        STTProviderSettings(
            providerType: .openAICompat,
            openAICompatBaseURL: "https://api.mistral.ai",
            openAICompatAPIKey: apiKey,
            openAICompatModel: "voxtral-mini-latest"
        )
    }

    /// OpenAI Whisper (requires API key).
    static func openAIWhisper(apiKey: String = "") -> STTProviderSettings {
        STTProviderSettings(
            providerType: .openAICompat,
            openAICompatBaseURL: "https://api.openai.com",
            openAICompatAPIKey: apiKey,
            openAICompatModel: "whisper-1"
        )
    }

    /// Local Voicebox server (default port 8880, local Whisper model, no key).
    static var voicebox: STTProviderSettings {
        STTProviderSettings(
            providerType: .openAICompat,
            openAICompatBaseURL: "http://127.0.0.1:8880",
            openAICompatAPIKey: "",
            openAICompatModel: "Systran/faster-whisper-small"
        )
    }

    /// Arbitrary OpenAI-compatible transcription server.
    static func custom(
        baseURL: String,
        model: String,
        apiKey: String = ""
    ) -> STTProviderSettings {
        STTProviderSettings(
            providerType: .openAICompat,
            openAICompatBaseURL: baseURL,
            openAICompatAPIKey: apiKey,
            openAICompatModel: model
        )
    }
}

// MARK: - Factory

enum STTProviderFactory {

    private static let userDefaultsKey = "sttProviderSettings"

    /// Creates the BuddyTranscriptionProvider described by `settings`.
    static func makeProvider(settings: STTProviderSettings) -> any BuddyTranscriptionProvider {
        switch settings.providerType {
        case .assemblyAI:
            return AssemblyAIStreamingTranscriptionProvider()

        case .openAICompat:
            return OpenAIAudioTranscriptionProvider(
                baseURL: settings.openAICompatBaseURL,
                apiKey: settings.openAICompatAPIKey.isEmpty ? nil : settings.openAICompatAPIKey,
                model: settings.openAICompatModel,
                displayName: "OpenAI-compatible"
            )

        case .appleSpeech:
            return AppleSpeechTranscriptionProvider()
        }
    }

    static func loadSettings() -> STTProviderSettings {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let settings = try? JSONDecoder().decode(STTProviderSettings.self, from: data) else {
            return STTProviderSettings()
        }
        return settings
    }

    static func saveSettings(_ settings: STTProviderSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: userDefaultsKey)
    }
}
