//
//  SettingsView.swift
//  leanring-buddy
//
//  The dedicated Settings window. A single "Providers" section manages the
//  shared pool of OpenAI-compatible endpoints (one API key each, entered ONCE),
//  and each slot (Brain / STT / TTS) references a provider by id instead of
//  re-entering its own baseURL+key. Bindings write into CompanionManager's
//  @Published providerStore, whose didSet rebuilds the live clients — so
//  changes take effect immediately.
//

import SwiftUI

struct SettingsView: View {
    @ObservedObject var companionManager: CompanionManager

    @State private var openCodeModels: [OpenCodeModelInfo] = []
    @State private var openCodeModelsLoading = false
    @State private var openCodeModelsError: String?
    @State private var openCodeFreeOnly = true

    // Brain / STT model + TTS voice catalog state (reloaded per fetch).
    @State private var brainModels: [OpenAIModelInfo] = []
    @State private var brainModelsLoading = false
    @State private var brainModelsError: String?

    @State private var sttModels: [OpenAIModelInfo] = []
    @State private var sttModelsLoading = false
    @State private var sttModelsError: String?

    @State private var ttsModels: [OpenAIModelInfo] = []
    @State private var ttsModelsLoading = false
    @State private var ttsModelsError: String?

    @State private var ttsVoices: [OpenAIVoiceInfo] = []
    @State private var ttsVoicesLoading = false
    @State private var ttsVoicesError: String?

    /// Persisted choice between the CGEvent executor (default) and the precise
    /// background BackgroundComputerUseKit executor. Read at CompanionManager
    /// init, so the change takes effect on next launch.
    @AppStorage(CompanionManager.useBackgroundComputerUseKey)
    private var useBackgroundComputerUse = false

    var body: some View {
        Form {
            providersSection
            brainSection
            transcriptionSection
            voiceSection
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 600)
    }

    // MARK: - Shared providers pool

    private var providersSection: some View {
        Section("Providers (shared API keys)") {
            Text("Add each OpenAI-compatible endpoint once — its API key is reused across the Brain, Speech-to-Text and Voice slots below. No more pasting the same key three times.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach($companionManager.providerStore.providers) { $provider in
                ProviderEditorRow(provider: $provider) {
                    removeProvider(provider.id)
                }
            }

            HStack {
                Button("Add provider") { addProvider() }
                Spacer()
                Menu("Add preset") {
                    Button("OpenAI") { addPreset(.openAIPreset) }
                    Button("Mistral") { addPreset(.mistralPreset) }
                    Button("LM Studio (local)") { addPreset(.lmStudioPreset) }
                    Button("Voicebox (local)") { addPreset(.voiceboxPreset) }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func addProvider() {
        companionManager.providerStore.providers.append(
            Provider(name: "New provider", baseURL: "https://", capabilities: .all)
        )
    }

    private func addPreset(_ p: Provider) {
        companionManager.providerStore.providers.append(p)
    }

    private func removeProvider(_ id: UUID) {
        var store = companionManager.providerStore
        store.providers.removeAll { $0.id == id }
        // Detach any slot that referenced the deleted provider.
        if store.brain.providerID == id { store.brain.providerID = nil }
        if store.stt.providerID == id { store.stt.providerID = nil }
        if store.tts.providerID == id { store.tts.providerID = nil }
        companionManager.providerStore = store
    }

    /// Picker over providers whose capabilities include `capability`.
    @ViewBuilder
    private func providerPicker(
        capability: ProviderCapabilities,
        selection: Binding<UUID?>
    ) -> some View {
        let eligible = companionManager.providerStore.providers.filter {
            $0.capabilities.contains(capability)
        }
        if eligible.isEmpty {
            Text("No provider with this capability — add one above.")
                .font(.caption)
                .foregroundStyle(.orange)
        } else {
            Picker("Provider", selection: selection) {
                Text("— select —").tag(UUID?.none)
                ForEach(eligible) { p in
                    Text(p.name).tag(UUID?.some(p.id))
                }
            }
        }
    }

    // MARK: - OpenCode model loading

    private func loadOpenCodeModels() {
        openCodeModelsLoading = true
        openCodeModelsError = nil
        let binary = companionManager.providerStore.brain.openCodeBinaryPath
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
            Picker("Provider type", selection: $companionManager.providerStore.brain.providerType) {
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

            switch companionManager.providerStore.brain.providerType {
            case .claudeWorker:
                TextField("Claude model", text: $companionManager.providerStore.brain.claudeModel)
                Text("Uses the Cloudflare Worker proxy configured in code.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

            case .openAICompat:
                providerPicker(
                    capability: .brain,
                    selection: $companionManager.providerStore.brain.providerID
                )
                modelPicker(
                    providerID: companionManager.providerStore.brain.providerID,
                    model: $companionManager.providerStore.brain.model,
                    models: $brainModels,
                    loading: $brainModelsLoading,
                    error: $brainModelsError,
                    modelFieldPrompt: "Model (must be a vision model)"
                )
                Text("The brain sees your screen → pick a vision model (Qwen-VL, Gemma 3 4B+).")
                    .font(.caption)
                    .foregroundStyle(.secondary)

            case .cliAgent:
                HStack {
                    Button("Claude Code") { setCLI("claude", "-p {prompt} --output-format text --dangerously-skip-permissions") }
                    Button("OpenCode") { setCLI("opencode", "run {prompt}") }
                    Button("Codex") { setCLI("codex", "exec {prompt}") }
                    Button("Cursor") { setCLI("cursor-agent", "{prompt}") }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                TextField("Command", text: $companionManager.providerStore.brain.cliCommand)
                TextField("Arguments ({prompt} = the prompt)", text: $companionManager.providerStore.brain.cliArgsTemplate)

                Text("Spawns the agent CLI as a subprocess; the screenshot is written to a temp file and its path is passed in the prompt. Slower than HTTP, and the agent must be able to read the image file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

            case .openCodeServer:
                TextField("Binary (name on PATH or absolute path)", text: $companionManager.providerStore.brain.openCodeBinaryPath)

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
                    TextField("Model (providerID/modelID — empty = server default)", text: $companionManager.providerStore.brain.openCodeModel)
                } else {
                    Toggle("Free models only (no API key needed)", isOn: $openCodeFreeOnly)
                    let shownModels = openCodeFreeOnly ? openCodeModels.filter(\.isFree) : openCodeModels
                    Picker("Model", selection: $companionManager.providerStore.brain.openCodeModel) {
                        Text("Server default").tag("")
                        ForEach(shownModels) { model in
                            Text(model.isFree ? "\(model.menuLabel)  · free" : model.menuLabel).tag(model.id)
                        }
                    }
                    if let selected = openCodeModels.first(where: { $0.id == companionManager.providerStore.brain.openCodeModel }) {
                        HStack(spacing: 10) {
                            Label("Vision", systemImage: selected.hasVision ? "eye.fill" : "eye.slash")
                                .foregroundStyle(selected.hasVision ? .green : .secondary)
                            Label("Reasoning", systemImage: "brain")
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

    private func setCLI(_ command: String, _ args: String) {
        companionManager.providerStore.brain.cliCommand = command
        companionManager.providerStore.brain.cliArgsTemplate = args
    }

    // MARK: - Speech-to-Text

    private var transcriptionSection: some View {
        Section("Speech-to-Text (STT)") {
            Picker("Provider type", selection: $companionManager.providerStore.stt.providerType) {
                ForEach(STTProviderType.allCases) { type in
                    Text(type.displayName).tag(type)
                }
            }

            switch companionManager.providerStore.stt.providerType {
            case .openAICompat:
                providerPicker(
                    capability: .stt,
                    selection: $companionManager.providerStore.stt.providerID
                )
                modelPicker(
                    providerID: companionManager.providerStore.stt.providerID,
                    model: $companionManager.providerStore.stt.model,
                    models: $sttModels,
                    loading: $sttModelsLoading,
                    error: $sttModelsError,
                    modelFieldPrompt: "Model (e.g. voxtral-mini-latest, whisper-1)"
                )
                Text("Any /v1/audio/transcriptions endpoint (Voxtral, OpenAI Whisper, Voicebox, LM Studio). STT needs only a model — there is no voice to set.")
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
            Picker("Provider type", selection: $companionManager.providerStore.tts.providerType) {
                ForEach(TTSProviderType.allCases) { type in
                    Text(type.displayName).tag(type)
                }
            }

            switch companionManager.providerStore.tts.providerType {
            case .openAICompat:
                providerPicker(
                    capability: .tts,
                    selection: $companionManager.providerStore.tts.providerID
                )
                modelPicker(
                    providerID: companionManager.providerStore.tts.providerID,
                    model: $companionManager.providerStore.tts.model,
                    models: $ttsModels,
                    loading: $ttsModelsLoading,
                    error: $ttsModelsError,
                    modelFieldPrompt: "Model (e.g. voxtral-mini-tts-2603, kokoro, tts-1)"
                )
                voicePicker
                Stepper(value: $companionManager.providerStore.tts.speed, in: 0.5...2.0, step: 0.1) {
                    Text("Speech rate: \(companionManager.providerStore.tts.speed, specifier: "%.1f")×")
                }

            case .elevenLabs:
                Text("Uses the Cloudflare Worker proxy configured in code.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

            case .system:
                Text("Apple system voice — offline, no configuration.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Model picker (shared by Brain / STT / TTS)
    //
    // Mirrors the OpenCode load-button + Picker + free-text-fallback pattern.

    @ViewBuilder
    private func modelPicker(
        providerID: UUID?,
        model: Binding<String>,
        models: Binding<[OpenAIModelInfo]>,
        loading: Binding<Bool>,
        error: Binding<String?>,
        modelFieldPrompt: String
    ) -> some View {
        let provider = companionManager.providerStore.provider(for: providerID)

        HStack {
            Button(loading.wrappedValue ? "Loading models…" : "Load models") {
                loadModels(provider: provider, into: models, loading: loading, error: error)
            }
            .disabled(loading.wrappedValue || provider == nil)
            if !models.wrappedValue.isEmpty {
                Text("\(models.wrappedValue.count) available").foregroundStyle(.secondary)
            }
        }

        if models.wrappedValue.isEmpty {
            TextField(modelFieldPrompt, text: model)
        } else {
            Picker("Model", selection: model) {
                // Keep the currently-set model selectable even if not in the list.
                if !models.wrappedValue.contains(where: { $0.id == model.wrappedValue }),
                   !model.wrappedValue.isEmpty {
                    Text(model.wrappedValue).tag(model.wrappedValue)
                }
                ForEach(models.wrappedValue) { m in
                    Text(m.menuLabel).tag(m.id)
                }
            }
        }

        if let err = error.wrappedValue {
            Text(err).font(.caption).foregroundStyle(.red)
        }
    }

    private func loadModels(
        provider: Provider?,
        into models: Binding<[OpenAIModelInfo]>,
        loading: Binding<Bool>,
        error: Binding<String?>
    ) {
        guard let provider else { return }
        let errorBinding = error
        loading.wrappedValue = true
        errorBinding.wrappedValue = nil
        let baseURL = provider.baseURL
        let apiKey = provider.apiKey.isEmpty ? nil : provider.apiKey
        Task { @MainActor in
            do {
                let result = try await OpenAIModelCatalog.fetch(baseURL: baseURL, apiKey: apiKey)
                models.wrappedValue = result
                if result.isEmpty { errorBinding.wrappedValue = "No models returned." }
            } catch {
                errorBinding.wrappedValue = "Couldn't load models: \(error.localizedDescription)"
            }
            loading.wrappedValue = false
        }
    }

    // MARK: - Voice picker (TTS only)

    @ViewBuilder
    private var voicePicker: some View {
        let provider = companionManager.providerStore.provider(for: companionManager.providerStore.tts.providerID)

        HStack {
            Button(ttsVoicesLoading ? "Loading voices…" : "Load voices") {
                loadVoices(provider: provider)
            }
            .disabled(ttsVoicesLoading || provider == nil)
            if !ttsVoices.isEmpty {
                Text("\(ttsVoices.count) available").foregroundStyle(.secondary)
            }
        }

        if ttsVoices.isEmpty {
            TextField("Voice (e.g. fr_marie_neutral, af_heart, nova)", text: $companionManager.providerStore.tts.voice)
        } else {
            Picker("Voice", selection: $companionManager.providerStore.tts.voice) {
                let current = companionManager.providerStore.tts.voice
                if !ttsVoices.contains(where: { $0.id == current }), !current.isEmpty {
                    Text(current).tag(current)
                }
                ForEach(ttsVoices) { v in
                    Text(v.menuLabel).tag(v.id)
                }
            }
        }

        if let ttsVoicesError {
            Text(ttsVoicesError).font(.caption).foregroundStyle(.red)
        }
    }

    private func loadVoices(provider: Provider?) {
        guard let provider else { return }
        ttsVoicesLoading = true
        ttsVoicesError = nil
        let baseURL = provider.baseURL
        let apiKey = provider.apiKey.isEmpty ? nil : provider.apiKey
        Task { @MainActor in
            do {
                let result = try await OpenAIVoiceCatalog.fetch(baseURL: baseURL, apiKey: apiKey)
                ttsVoices = result
                if result.isEmpty { ttsVoicesError = "No voices returned." }
            } catch {
                ttsVoicesError = "Couldn't load voices: \(error.localizedDescription)"
            }
            ttsVoicesLoading = false
        }
    }
}

// MARK: - Provider preset factories

private extension Provider {
    static var openAIPreset: Provider {
        Provider(name: "OpenAI", baseURL: "https://api.openai.com", capabilities: .all,
                 docsURL: "https://platform.openai.com/docs",
                 apiKeyURL: "https://platform.openai.com/api-keys")
    }
    static var mistralPreset: Provider {
        Provider(name: "Mistral", baseURL: "https://api.mistral.ai", capabilities: [.stt, .tts],
                 docsURL: "https://docs.mistral.ai",
                 apiKeyURL: "https://console.mistral.ai/api-keys")
    }
    static var lmStudioPreset: Provider {
        Provider(name: "LM Studio (local)", baseURL: "http://localhost:1234", capabilities: .brain,
                 docsURL: "https://lmstudio.ai/docs")
    }
    static var voiceboxPreset: Provider {
        Provider(name: "Voicebox (local)", baseURL: "http://127.0.0.1:8880", capabilities: [.stt, .tts])
    }
}

// MARK: - Provider editor row

/// One row in the Providers pool: name, base URL, single API key (entered once),
/// capability toggles, doc/key links, and a delete button.
private struct ProviderEditorRow: View {
    @Binding var provider: Provider
    let onDelete: () -> Void

    var body: some View {
        DisclosureGroup {
            TextField("Name", text: $provider.name)
            TextField("Base URL", text: $provider.baseURL)
                .textContentType(.URL)
            APIKeyField(title: "API key (leave empty for local)", key: $provider.apiKey)

            HStack(spacing: 16) {
                Toggle("Brain", isOn: capabilityBinding(.brain))
                Toggle("STT", isOn: capabilityBinding(.stt))
                Toggle("TTS", isOn: capabilityBinding(.tts))
            }
            .toggleStyle(.checkbox)
            .font(.caption)

            HStack(spacing: 16) {
                if let docs = provider.docsURL, let url = URL(string: docs) {
                    Link("Documentation", destination: url)
                }
                if let keyURL = provider.apiKeyURL, let url = URL(string: keyURL) {
                    Link("Get API key", destination: url)
                }
            }
            .font(.caption)

            Button("Delete provider", role: .destructive, action: onDelete)
                .controlSize(.small)
        } label: {
            HStack {
                Text(provider.name.isEmpty ? "Unnamed provider" : provider.name)
                    .fontWeight(.medium)
                Spacer()
                Text(capabilitySummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var capabilitySummary: String {
        var parts: [String] = []
        if provider.capabilities.contains(.brain) { parts.append("Brain") }
        if provider.capabilities.contains(.stt) { parts.append("STT") }
        if provider.capabilities.contains(.tts) { parts.append("TTS") }
        return parts.joined(separator: " · ")
    }

    private func capabilityBinding(_ cap: ProviderCapabilities) -> Binding<Bool> {
        Binding(
            get: { provider.capabilities.contains(cap) },
            set: { isOn in
                if isOn { provider.capabilities.insert(cap) }
                else { provider.capabilities.remove(cap) }
            }
        )
    }
}

// MARK: - API key field

/// Single-line API-key input with a reveal (eye) toggle. Avoids the multi-line
/// behaviour of a bare TextField and lets the user verify what they pasted.
struct APIKeyField: View {
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
