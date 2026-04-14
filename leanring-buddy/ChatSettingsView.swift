//
//  ChatSettingsView.swift
//  leanring-buddy
//
//  Settings page shown inside the Clicky chat window when the user
//  clicks the gear icon. Provides model selection, TTS/STT provider
//  pickers, and API key configuration — all styled with the dark DS
//  theme to match the rest of the chat window.
//

import SwiftUI

struct ChatSettingsView: View {
    @ObservedObject var companionManager: CompanionManager
    let onDismiss: () -> Void

    @State private var apiKeyInput = ""
    @State private var isAPIKeyVisible = false

    // Profile section state — pre-filled from companionManager.userProfile on appear
    @State private var profileNickname: String = ""
    @State private var profileGoals: String = ""
    @State private var profileAdditionalContext: String = ""
    @State private var profileSaveStatus: String = ""

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 24) {
                profileSection
                modelSection
                voiceSection
                speechSection
            }
            .padding(24)
        }
        .background(DS.Colors.background)
        .navigationTitle("Settings")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done", action: onDismiss)
            }
        }
        .onAppear {
            if companionManager.isUsingDirectAPIKey {
                apiKeyInput = companionManager.anthropicAPIKey
            }
            companionManager.fetchAvailableLMStudioModels()
            // Pre-fill profile fields from the saved profile
            let savedProfile = companionManager.userProfile
            profileNickname = savedProfile.nickname
            profileGoals = savedProfile.goals
            profileAdditionalContext = savedProfile.additionalContext
        }
    }

    // MARK: - Profile

    /// A personal context card that gets prepended to every Claude system prompt.
    /// The more the user fills in, the more Clicky can personalize its responses
    /// and keep conversations oriented around their actual goals.
    private var profileSection: some View {
        settingsSection(title: "Profile") {
            VStack(alignment: .leading, spacing: 12) {
                settingsHint("Tell Clicky who you are. This gets added to every conversation so responses are always personalized to you.")

                // Nickname
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your name")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(DS.Colors.textSecondary)

                    TextField("e.g. joce", text: $profileNickname)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundColor(DS.Colors.textPrimary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.white.opacity(0.06))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                        )
                }

                // Goals
                VStack(alignment: .leading, spacing: 4) {
                    Text("Goals")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(DS.Colors.textSecondary)

                    settingsHint("What you want to get better at or accomplish")

                    profileTextEditor(
                        placeholder: "e.g. get better at coding, create nice projects, do more with less",
                        text: $profileGoals,
                        minHeight: 56
                    )
                }

                // Additional context
                VStack(alignment: .leading, spacing: 4) {
                    Text("Additional context")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(DS.Colors.textSecondary)

                    settingsHint("Preferred tools, learning style, current projects — anything useful")

                    profileTextEditor(
                        placeholder: "e.g. I'm learning DaVinci Resolve. I prefer concise answers with examples.",
                        text: $profileAdditionalContext,
                        minHeight: 72
                    )
                }

                // Save button + status
                HStack {
                    if !profileSaveStatus.isEmpty {
                        settingsHint(profileSaveStatus)
                    }
                    Spacer()
                    Button(action: saveProfile) {
                        Text("Save")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Colors.textPrimary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(DS.Colors.accent.opacity(0.85))
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }
        }
    }

    private func saveProfile() {
        let updatedProfile = UserProfile(
            nickname: profileNickname,
            goals: profileGoals,
            additionalContext: profileAdditionalContext
        )
        companionManager.saveUserProfile(updatedProfile)
        profileSaveStatus = "Saved"
        // Clear the status after 2 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            profileSaveStatus = ""
        }
    }

    /// A styled multi-line text editor for profile fields. SwiftUI's TextEditor doesn't
    /// support placeholder text natively, so we layer a hint label behind it.
    private func profileTextEditor(placeholder: String, text: Binding<String>, minHeight: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            if text.wrappedValue.isEmpty {
                Text(placeholder)
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textTertiary)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 10)
                    .allowsHitTesting(false)
            }

            TextEditor(text: text)
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textPrimary)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .frame(minHeight: minHeight)
        }
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
        )
    }

    // MARK: - Model

    private var modelSection: some View {
        settingsSection(title: "Model") {
            HStack(spacing: 0) {
                modelProviderOptionButton(label: "Anthropic", providerID: "anthropic")
                modelProviderOptionButton(label: "LM Studio", providerID: "lmstudio")
                modelProviderOptionButton(label: "Apple", providerID: "local")
            }
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
            )

            if companionManager.selectedModel == "lmstudio" {
                settingsHint("Vision \u{00B7} local \u{00B7} configure LM Studio below")
            } else if companionManager.selectedModel == "local" && !companionManager.isAppleIntelligenceAvailable {
                settingsHint("Requires macOS 26+ with Apple Intelligence enabled", isWarning: true)
            } else if companionManager.selectedModel == "local" {
                settingsHint("Text-only \u{00B7} no screenshots \u{00B7} on-device")
            }

            if selectedModelProvider == "anthropic" {
                HStack(spacing: 0) {
                    anthropicModelOptionButton(label: "Sonnet", modelID: "claude-sonnet-4-6")
                    anthropicModelOptionButton(label: "Opus", modelID: "claude-opus-4-6")
                }
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                )

                apiKeySection
            } else if selectedModelProvider == "lmstudio" {
                lmStudioSection
            }
        }
    }

    @ViewBuilder
    private func modelIcon(_ modelID: String, size: CGFloat = 14) -> some View {
        switch modelID {
        case "claude-opus-4-6", "claude-sonnet-4-6":
            Image("icon-anthropic").resizable().scaledToFit().frame(width: size, height: size)
        case "lmstudio":
            Image("icon-lmstudio").resizable().scaledToFit().frame(width: size, height: size)
        case "local":
            Image(systemName: "apple.logo").font(.system(size: size * 0.85))
        default:
            EmptyView()
        }
    }

    private func modelProviderOptionButton(label: String, providerID: String) -> some View {
        let isSelected = selectedModelProvider == providerID
        return Button(action: {
            setSelectedModelProvider(providerID)
        }) {
            HStack(spacing: 4) {
                modelProviderIcon(providerID)
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textTertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isSelected ? Color.white.opacity(0.1) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    @ViewBuilder
    private func modelProviderIcon(_ providerID: String, size: CGFloat = 14) -> some View {
        switch providerID {
        case "anthropic":
            Image("icon-anthropic").resizable().scaledToFit().frame(width: size, height: size)
        case "lmstudio":
            Image("icon-lmstudio").resizable().scaledToFit().frame(width: size, height: size)
        case "local":
            Image(systemName: "apple.logo").font(.system(size: size * 0.85))
        default:
            EmptyView()
        }
    }

    private func anthropicModelOptionButton(label: String, modelID: String) -> some View {
        let isSelected = companionManager.selectedModel == modelID
        return Button(action: {
            companionManager.setSelectedModel(modelID)
        }) {
            HStack(spacing: 4) {
                modelIcon(modelID)
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textTertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.1) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private var selectedModelProvider: String {
        switch companionManager.selectedModel {
        case "lmstudio":
            return "lmstudio"
        case "local":
            return "local"
        default:
            return "anthropic"
        }
    }

    private func setSelectedModelProvider(_ providerID: String) {
        switch providerID {
        case "anthropic":
            if companionManager.selectedModel != "claude-opus-4-6" {
                companionManager.setSelectedModel("claude-sonnet-4-6")
            } else {
                companionManager.setSelectedModel("claude-opus-4-6")
            }
        case "lmstudio":
            companionManager.setSelectedModel("lmstudio")
        case "local":
            companionManager.setSelectedModel("local")
        default:
            break
        }
    }

    // MARK: - Voice (TTS)

    private var voiceSection: some View {
        settingsSection(title: "Voice") {
            HStack {
                HStack(spacing: 0) {
                    ttsOptionButton(label: "ElevenLabs", providerID: "elevenlabs")
                    ttsOptionButton(label: "Supertonic", providerID: "supertonic")
                }
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                )

                Spacer()

                Button(action: { companionManager.testCurrentTTSProvider() }) {
                    Text("Test")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color.white.opacity(0.1))
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }

            if !companionManager.ttsTestStatus.isEmpty {
                settingsHint(companionManager.ttsTestStatus)
            }
        }
    }

    private func ttsOptionButton(label: String, providerID: String) -> some View {
        let isSelected = companionManager.selectedTTSProvider == providerID
        return Button(action: {
            companionManager.setSelectedTTSProvider(providerID)
        }) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isSelected ? Color.white.opacity(0.1) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    // MARK: - Speech (STT)

    private var speechSection: some View {
        settingsSection(title: "Speech") {
            HStack {
                HStack(spacing: 0) {
                    sttOptionButton(label: "AssemblyAI", providerID: "assemblyai")
                    sttOptionButton(label: "Parakeet", providerID: "parakeet")
                }
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                )

                Spacer()

                Button(action: { companionManager.testCurrentSTTProvider() }) {
                    Text("Test")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color.white.opacity(0.1))
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }

            if !companionManager.sttTestStatus.isEmpty {
                settingsHint(companionManager.sttTestStatus)
            }
        }
    }

    private func sttOptionButton(label: String, providerID: String) -> some View {
        let isSelected = companionManager.selectedSTTProvider == providerID
        return Button(action: {
            companionManager.setSelectedSTTProvider(providerID)
        }) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isSelected ? Color.white.opacity(0.1) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    // MARK: - API Key

    private var apiKeySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Anthropic API Key")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)

            HStack {
                if companionManager.isUsingDirectAPIKey {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(DS.Colors.success)
                            .frame(width: 6, height: 6)
                        Text("Direct")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(DS.Colors.success)
                    }
                } else {
                    Text("Using proxy")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }

            HStack(spacing: 8) {
                ZStack {
                    if isAPIKeyVisible {
                        TextField("sk-ant-...", text: $apiKeyInput)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(DS.Colors.textPrimary)
                    } else {
                        SecureField("sk-ant-...", text: $apiKeyInput)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(DS.Colors.textPrimary)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                )
                .onSubmit {
                    companionManager.setAnthropicAPIKey(apiKeyInput)
                }

                Button(action: { isAPIKeyVisible.toggle() }) {
                    Image(systemName: isAPIKeyVisible ? "eye.slash.fill" : "eye.fill")
                        .font(.system(size: 13))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help(isAPIKeyVisible ? "Hide API Key" : "Show API Key")

                if companionManager.isUsingDirectAPIKey {
                    Button(action: {
                        apiKeyInput = ""
                        companionManager.setAnthropicAPIKey("")
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                } else {
                    Button(action: {
                        companionManager.setAnthropicAPIKey(apiKeyInput)
                    }) {
                        Text("Save")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Colors.textPrimary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(Color.white.opacity(0.1))
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            HStack {
                settingsHint("Stored securely in macOS Keychain")

                Spacer()

                if companionManager.isUsingDirectAPIKey {
                    Button(action: { companionManager.testAnthropicAPIKey() }) {
                        Text("Test")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Colors.textPrimary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(Color.white.opacity(0.1))
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }

            if !companionManager.apiKeyTestStatus.isEmpty {
                settingsHint(companionManager.apiKeyTestStatus)
            }
        }
    }

    // MARK: - LM Studio

    private var lmStudioSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("LM Studio")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)

            HStack {
                Spacer()
                Button(action: { companionManager.fetchAvailableLMStudioModels() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Refresh")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundColor(DS.Colors.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.white.opacity(0.1))
                    )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }

            if companionManager.availableLMStudioModels.isEmpty {
                settingsHint("No models found — is LM Studio running on port 1234?")
            } else {
                Menu {
                    ForEach(companionManager.availableLMStudioModels, id: \.self) { modelID in
                        Button(action: { companionManager.setSelectedLMStudioModel(modelID) }) {
                            HStack {
                                Text(modelID)
                                if companionManager.selectedLMStudioModel == modelID {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack {
                        Text(companionManager.selectedLMStudioModel.isEmpty
                             ? "Select model..."
                             : companionManager.selectedLMStudioModel)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(companionManager.selectedLMStudioModel.isEmpty
                                             ? DS.Colors.textTertiary
                                             : DS.Colors.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer()

                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                    )
                }
                .menuStyle(.borderlessButton)
            }

            // OCR toggle
            HStack {
                Text("Screen text extraction (OCR)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)

                Spacer()

                Toggle("", isOn: Binding(
                    get: { companionManager.isOCRExtractionEnabled },
                    set: { companionManager.setOCRExtractionEnabled($0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(DS.Colors.accent)
                .scaleEffect(0.8)
            }
        }
    }

    // MARK: - Reusable Components

    private func settingsSection<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)

            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large)
                .fill(DS.Colors.surface1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large)
                .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
        )
    }

    private func settingsHint(_ text: String, isWarning: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(isWarning ? DS.Colors.warning : DS.Colors.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
