//
//  BrainProviderSettings.swift
//  leanring-buddy
//
//  Brain (LLM) provider configuration, persisted to UserDefaults.
//  Mirrors TTSProviderSettings: one enum covers all OpenAI-compatible
//  vision endpoints (LM Studio local, OpenAI, Gemini-compat, any server),
//  plus the existing Claude-via-Worker path.
//
//  NOTE: the brain receives screenshots, so an OpenAI-compatible model must be
//  a VISION (VL / multimodal) model — e.g. Qwen-VL, Gemma 3 (4B+). Text-only
//  models won't "see" the screen.
//

import Foundation

// MARK: - Provider type

enum BrainProviderType: String, Codable, CaseIterable, Identifiable {
    /// Anthropic Claude via the Cloudflare Worker proxy (default; key stays server-side).
    case claudeWorker = "claude_worker"
    /// Any OpenAI-compatible /v1/chat/completions endpoint with vision
    /// (LM Studio local, OpenAI, Gemini-compat, custom server).
    case openAICompat = "openai_compat"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claudeWorker: return "Claude (Worker proxy)"
        case .openAICompat: return "OpenAI-compatible (LM Studio / API key)"
        }
    }
}

// MARK: - Settings

struct BrainProviderSettings: Codable {
    var providerType: BrainProviderType = .claudeWorker

    /// Claude model used when `providerType == .claudeWorker`.
    var claudeModel: String = "claude-sonnet-4-6"

    // OpenAI-compat settings — apply to LM Studio, OpenAI, Gemini-compat, custom.
    var openAICompatBaseURL: String = "http://localhost:1234"   // LM Studio default
    var openAICompatAPIKey: String  = ""                        // empty for local servers
    var openAICompatModel: String   = "qwen2.5-vl-7b-instruct"  // must be a vision model
}

// MARK: - Named presets

extension BrainProviderSettings {
    /// LM Studio local server (default port 1234, no key). Set `model` to a loaded VL model.
    static func lmStudio(model: String = "qwen2.5-vl-7b-instruct") -> BrainProviderSettings {
        BrainProviderSettings(
            providerType: .openAICompat,
            openAICompatBaseURL: "http://localhost:1234",
            openAICompatAPIKey: "",
            openAICompatModel: model
        )
    }

    /// OpenAI (requires API key). Defaults to a vision-capable model.
    static func openAI(apiKey: String, model: String = "gpt-4o") -> BrainProviderSettings {
        BrainProviderSettings(
            providerType: .openAICompat,
            openAICompatBaseURL: "https://api.openai.com",
            openAICompatAPIKey: apiKey,
            openAICompatModel: model
        )
    }

    /// Arbitrary OpenAI-compatible vision server.
    static func custom(baseURL: String, model: String, apiKey: String = "") -> BrainProviderSettings {
        BrainProviderSettings(
            providerType: .openAICompat,
            openAICompatBaseURL: baseURL,
            openAICompatAPIKey: apiKey,
            openAICompatModel: model
        )
    }
}

// MARK: - Factory

enum BrainProviderFactory {

    private static let userDefaultsKey = "brainProviderSettings"

    /// Creates the BrainClient described by `settings`.
    /// - Parameter claudeProxyURL: the Cloudflare Worker `/chat` URL, used when
    ///   `providerType == .claudeWorker`. Pass `CompanionManager.workerBaseURL + "/chat"`.
    static func makeClient(
        settings: BrainProviderSettings,
        claudeProxyURL: String
    ) -> any BrainClient {
        switch settings.providerType {
        case .claudeWorker:
            return ClaudeAPI(proxyURL: claudeProxyURL, model: settings.claudeModel)

        case .openAICompat:
            return OpenAICompatibleBrainAdapter(
                baseURL: settings.openAICompatBaseURL,
                model: settings.openAICompatModel,
                apiKey: settings.openAICompatAPIKey.isEmpty ? nil : settings.openAICompatAPIKey
            )
        }
    }

    static func loadSettings() -> BrainProviderSettings {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let settings = try? JSONDecoder().decode(BrainProviderSettings.self, from: data) else {
            return BrainProviderSettings()
        }
        return settings
    }

    static func saveSettings(_ settings: BrainProviderSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: userDefaultsKey)
    }
}
