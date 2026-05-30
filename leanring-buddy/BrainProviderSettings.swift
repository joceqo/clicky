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
    /// A local agent CLI driven as a subprocess (Claude Code, OpenCode, Codex, Cursor).
    case cliAgent = "cli_agent"
    /// A persistent `opencode serve` HTTP server reusing one session across turns —
    /// no per-turn cold start, multi-turn context kept server-side.
    case openCodeServer = "opencode_server"
    /// On-device OCR (Vision) + Apple Intelligence LLM. Low-compute, text-only
    /// (reads screen text, can't see images). Requires macOS 26 + Apple Intelligence.
    case appleOCR = "apple_ocr"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claudeWorker:   return "Claude (Worker proxy)"
        case .openAICompat:   return "OpenAI-compatible (LM Studio / API key)"
        case .cliAgent:       return "Agent CLI (Claude Code / OpenCode / Codex / Cursor)"
        case .openCodeServer: return "OpenCode (persistent server)"
        case .appleOCR:       return "Apple OCR + on-device LLM (light, text-only)"
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

    // CLI agent settings — drive a local agent binary as a subprocess.
    // `cliArgsTemplate` is whitespace-split into arguments; the `{prompt}` token
    // is replaced (as a single argument) by the composed prompt.
    var cliCommand: String      = "claude"
    var cliArgsTemplate: String = "-p {prompt} --output-format text --dangerously-skip-permissions"

    // OpenCode persistent-server settings.
    // `openCodeModel` is a `providerID/modelID` selector (e.g. "anthropic/claude-sonnet-4-5");
    // empty means "use the server's configured default model".
    var openCodeModel: String      = ""
    var openCodeBinaryPath: String = "opencode"
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

    // ── Agent CLI presets ───────────────────────────────────────────────
    // Commands resolve via an augmented PATH (Homebrew, ~/.local/bin) in the adapter,
    // so bare names work even though GUI apps don't inherit the shell PATH.

    static var claudeCode: BrainProviderSettings {
        var s = BrainProviderSettings(); s.providerType = .cliAgent
        s.cliCommand = "claude"
        s.cliArgsTemplate = "-p {prompt} --output-format text --dangerously-skip-permissions"
        return s
    }

    static var openCode: BrainProviderSettings {
        var s = BrainProviderSettings(); s.providerType = .cliAgent
        s.cliCommand = "opencode"
        s.cliArgsTemplate = "run {prompt}"
        return s
    }

    static var codex: BrainProviderSettings {
        var s = BrainProviderSettings(); s.providerType = .cliAgent
        s.cliCommand = "codex"
        s.cliArgsTemplate = "exec {prompt}"
        return s
    }

    static var cursorAgent: BrainProviderSettings {
        var s = BrainProviderSettings(); s.providerType = .cliAgent
        s.cliCommand = "cursor-agent"
        s.cliArgsTemplate = "{prompt}"
        return s
    }

    /// Persistent `opencode serve` server, reusing one session across turns.
    static var openCodeServer: BrainProviderSettings {
        var s = BrainProviderSettings(); s.providerType = .openCodeServer
        s.openCodeBinaryPath = "opencode"
        s.openCodeModel = ""
        return s
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

        case .cliAgent:
            let args = settings.cliArgsTemplate
                .split(whereSeparator: { $0 == " " || $0 == "\n" })
                .map(String.init)
            return CLIAgentBrainAdapter(command: settings.cliCommand, argsTemplate: args)

        case .openCodeServer:
            return OpenCodeServerBrainClient(
                model: settings.openCodeModel,
                binaryPath: settings.openCodeBinaryPath
            )

        case .appleOCR:
            return AppleOCRBrainAdapter()
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
