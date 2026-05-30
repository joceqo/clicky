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

    var body: some View {
        Form {
            brainSection
            voiceSection
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, minHeight: 520)
    }

    // MARK: - Brain

    private var brainSection: some View {
        Section("Brain (LLM)") {
            Picker("Provider", selection: $companionManager.brainProviderSettings.providerType) {
                ForEach(BrainProviderType.allCases) { type in
                    Text(type.displayName).tag(type)
                }
            }

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
                SecureField("API key (leave empty for local)", text: $companionManager.brainProviderSettings.openAICompatAPIKey)

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
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                TextField("Base URL", text: $companionManager.ttsProviderSettings.openAICompatBaseURL)
                    .textContentType(.URL)
                TextField("Model", text: $companionManager.ttsProviderSettings.openAICompatModel)
                TextField("Voice", text: $companionManager.ttsProviderSettings.openAICompatVoice)
                SecureField("API key (leave empty for local)", text: $companionManager.ttsProviderSettings.openAICompatAPIKey)
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
