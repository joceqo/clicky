//
//  SettingsView.swift
//  leanring-buddy
//
//  The dedicated Settings window content: pick the brain (LLM) backend and
//  the voice (TTS) backend, enter endpoints / API keys. Bindings write straight
//  into CompanionManager's @Published settings, whose didSet rebuilds the live
//  client — so changes take effect immediately.
//

import SwiftUI

struct SettingsView: View {
    @ObservedObject var companionManager: CompanionManager

    @State private var openCodeModels: [OpenCodeModelInfo] = []
    @State private var openCodeModelsLoading = false
    @State private var openCodeModelsError: String?
    @State private var openCodeFreeOnly = true

    /// Persisted choice between the CGEvent executor (default) and the precise
    /// background BackgroundComputerUseKit executor. Read at CompanionManager
    /// init, so the change takes effect on next launch.
    @AppStorage(CompanionManager.useBackgroundComputerUseKey)
    private var useBackgroundComputerUse = false

    var body: some View {
        Form {
            brainSection
            transcriptionSection
            voiceSection
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, minHeight: 520)
    }

    // MARK: - OpenCode model loading

    private func loadOpenCodeModels() {
        openCodeModelsLoading = true
        openCodeModelsError = nil
        let binary = companionManager.brainProviderSettings.openCodeBinaryPath
        Task { @MainActor in
            do {
                let baseURL = try await OpenCodeServerManager.shared.ensureRunning(
                    binaryPath: binary.isEmpty ? "opencode" : binary
                )
                let models = try await OpenCodeModelCatalog.fetch(baseURL: baseURL)
                openCodeModels = models
                if models.isEmpty { openCodeModelsError = "No models returned by the server." }
            } catch {
                openCodeModelsError = "Couldn't load models: \(error.localizedDescription)"
            }
            openCodeModelsLoading = false
        }
    }

    // MARK: - Brain

    private var brainSection: some View {
        Section("Brain (LLM)") {
            Picker("Provider", selection: $companionManager.brainProviderSettings.providerType) {
                ForEach(BrainProviderType.allCases) { type in
                    Text(type.displayName).tag(type)
                }
            }

            Label(
                "Pointing & clicking need a capable vision model. Claude points and clicks reliably; small or free models often don't emit the [POINT]/[CLICK] tags.",
                systemImage: "cursorarrow.rays"
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            switch companionManager.brainProviderSettings.providerType {
            case .claudeWorker:
                TextField("Claude model", text: $companionManager.brainProviderSettings.claudeModel)
                Text("Uses the Cloudflare Worker proxy configured in code.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

            case .openAICompat:
                HStack {
                    Button("LM Studio") {
                        companionManager.brainProviderSettings = .lmStudio(
                            model: companionManager.brainProviderSettings.openAICompatModel
                        )
                    }
                    Button("OpenAI") {
                        companionManager.brainProviderSettings = .openAI(
                            apiKey: companionManager.brainProviderSettings.openAICompatAPIKey
                        )
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                TextField("Base URL", text: $companionManager.brainProviderSettings.openAICompatBaseURL)
                    .textContentType(.URL)
                TextField("Model (must be a vision model)", text: $companionManager.brainProviderSettings.openAICompatModel)
                APIKeyField(title: "API key (leave empty for local)", key: $companionManager.brainProviderSettings.openAICompatAPIKey)

                Text("The brain sees your screen → pick a vision model (Qwen-VL, Gemma 3 4B+). LM Studio default: http://localhost:1234")
                    .font(.caption)
                    .foregroundStyle(.secondary)

            case .cliAgent:
                HStack {
                    Button("Claude Code") { companionManager.brainProviderSettings = .claudeCode }
                    Button("OpenCode") { companionManager.brainProviderSettings = .openCode }
                    Button("Codex") { companionManager.brainProviderSettings = .codex }
                    Button("Cursor") { companionManager.brainProviderSettings = .cursorAgent }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                TextField("Command", text: $companionManager.brainProviderSettings.cliCommand)
                TextField("Arguments ({prompt} = the prompt)", text: $companionManager.brainProviderSettings.cliArgsTemplate)

                Text("Spawns the agent CLI as a subprocess; the screenshot is written to a temp file and its path is passed in the prompt. Slower than HTTP, and the agent must be able to read the image file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

            case .openCodeServer:
                TextField("Binary (name on PATH or absolute path)", text: $companionManager.brainProviderSettings.openCodeBinaryPath)

                HStack {
                    Button(openCodeModelsLoading ? "Loading models…" : "Load models") {
                        loadOpenCodeModels()
                    }
                    .disabled(openCodeModelsLoading)
                    if !openCodeModels.isEmpty {
                        Text("\(openCodeModels.count) available").foregroundStyle(.secondary)
                    }
                }

                if openCodeModels.isEmpty {
                    // Fallback before models are loaded (or if loading fails): type the slug.
                    TextField("Model (providerID/modelID — empty = server default)", text: $companionManager.brainProviderSettings.openCodeModel)
                } else {
                    Toggle("Free models only (no API key needed)", isOn: $openCodeFreeOnly)
                    let shownModels = openCodeFreeOnly ? openCodeModels.filter(\.isFree) : openCodeModels
                    Picker("Model", selection: $companionManager.brainProviderSettings.openCodeModel) {
                        Text("Server default").tag("")
                        ForEach(shownModels) { model in
                            Text(model.isFree ? "\(model.menuLabel)  · free" : model.menuLabel).tag(model.id)
                        }
                    }
                    if let selected = openCodeModels.first(where: { $0.id == companionManager.brainProviderSettings.openCodeModel }) {
                        HStack(spacing: 10) {
                            Label("Vision", systemImage: selected.hasVision ? "eye.fill" : "eye.slash")
                                .foregroundStyle(selected.hasVision ? .green : .secondary)
                            Label("Reasoning", systemImage: selected.hasReasoning ? "brain" : "brain")
                                .foregroundStyle(selected.hasReasoning ? .green : .secondary)
                            Label("Tools", systemImage: selected.hasTools ? "wrench.and.screwdriver.fill" : "wrench.and.screwdriver")
                                .foregroundStyle(selected.hasTools ? .green : .secondary)
                        }
                        .font(.caption)
                        .labelStyle(.titleAndIcon)
                        if !selected.hasVision {
                            Text("No vision → the screenshot is OCR'd on-device and sent as text.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let openCodeModelsError {
                    Text(openCodeModelsError).font(.caption).foregroundStyle(.red)
                }

                Text("Runs `opencode serve` in the background and reuses a persistent session — no per-turn cold start, multi-turn context kept server-side. Requires `opencode` with a provider authenticated (`opencode auth login`).")
                    .font(.caption)
                    .foregroundStyle(.secondary)

            case .appleOCR:
                Text("On-device OCR (Vision) extracts the screen's text, then Apple Intelligence reasons over it. Fully local, free, light on the Mac — but text-only (can't see images/layout). Requires macOS 26 + Apple Intelligence enabled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle("Precise background click (experimental)", isOn: $useBackgroundComputerUse)
            Text("Clicks the target window in the background via Accessibility — no pointer takeover. Off uses the classic CGEvent click that moves the real cursor. Takes effect on next launch.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Speech-to-Text

    private var transcriptionSection: some View {
        Section("Speech-to-Text (STT)") {
            Picker("Provider", selection: $companionManager.sttProviderSettings.providerType) {
                ForEach(STTProviderType.allCases) { type in
                    Text(type.displayName).tag(type)
                }
            }

            switch companionManager.sttProviderSettings.providerType {
            case .openAICompat:
                HStack {
                    Button("Voxtral") {
                        companionManager.sttProviderSettings = .voxtral(
                            apiKey: companionManager.sttProviderSettings.openAICompatAPIKey
                        )
                    }
                    Button("OpenAI") {
                        companionManager.sttProviderSettings = .openAIWhisper(
                            apiKey: companionManager.sttProviderSettings.openAICompatAPIKey
                        )
                    }
                    Button("Voicebox") {
                        companionManager.sttProviderSettings = .voicebox
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                TextField("Base URL", text: $companionManager.sttProviderSettings.openAICompatBaseURL)
                    .textContentType(.URL)
                TextField("Model", text: $companionManager.sttProviderSettings.openAICompatModel)
                APIKeyField(title: "API key (leave empty for local)", key: $companionManager.sttProviderSettings.openAICompatAPIKey)

                Text("Any /v1/audio/transcriptions endpoint (Voxtral, OpenAI Whisper, Voicebox, LM Studio). STT needs only a URL, key, and model — there is no voice to set. Voicebox default: http://127.0.0.1:8880")
                    .font(.caption)
                    .foregroundStyle(.secondary)

            case .assemblyAI:
                Text("Real-time streaming transcription via the Cloudflare Worker proxy configured in code.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

            case .appleSpeech:
                Text("Apple Speech framework — on-device, offline, no configuration. Requires speech recognition permission.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Voice

    private var voiceSection: some View {
        Section("Voice (TTS)") {
            Picker("Provider", selection: $companionManager.ttsProviderSettings.providerType) {
                ForEach(TTSProviderType.allCases) { type in
                    Text(type.displayName).tag(type)
                }
            }

            if companionManager.ttsProviderSettings.providerType == .openAICompat {
                HStack {
                    Button("Voicebox") {
                        companionManager.ttsProviderSettings = .voicebox
                    }
                    Button("OpenAI") {
                        companionManager.ttsProviderSettings = .openAI(
                            apiKey: companionManager.ttsProviderSettings.openAICompatAPIKey
                        )
                    }
                    Button("Mistral") {
                        companionManager.ttsProviderSettings = .mistral(
                            apiKey: companionManager.ttsProviderSettings.openAICompatAPIKey
                        )
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                TextField("Base URL", text: $companionManager.ttsProviderSettings.openAICompatBaseURL)
                    .textContentType(.URL)
                TextField("Model", text: $companionManager.ttsProviderSettings.openAICompatModel)
                TextField("Voice", text: $companionManager.ttsProviderSettings.openAICompatVoice)
                Stepper(value: $companionManager.ttsProviderSettings.openAICompatSpeed, in: 0.5...2.0, step: 0.1) {
                    Text("Speech rate: \(companionManager.ttsProviderSettings.openAICompatSpeed, specifier: "%.1f")×")
                }
                APIKeyField(title: "API key (leave empty for local)", key: $companionManager.ttsProviderSettings.openAICompatAPIKey)
            } else if companionManager.ttsProviderSettings.providerType == .elevenLabs {
                Text("Uses the Cloudflare Worker proxy configured in code.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Apple system voice — offline, no configuration.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - API key field

/// Single-line API-key input with a reveal (eye) toggle. Avoids the multi-line
/// behaviour of a bare TextField and lets the user verify what they pasted.
private struct APIKeyField: View {
    let title: String
    @Binding var key: String
    @State private var isRevealed = false

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if isRevealed {
                    TextField(title, text: $key)
                } else {
                    SecureField(title, text: $key)
                }
            }
            .textFieldStyle(.roundedBorder)
            .lineLimit(1)
            .autocorrectionDisabled()
            .textContentType(.password)

            Button {
                isRevealed.toggle()
            } label: {
                Image(systemName: isRevealed ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
            .help(isRevealed ? "Hide" : "Show")
        }
    }
}
