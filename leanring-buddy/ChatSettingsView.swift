//
//  ChatSettingsView.swift
//  leanring-buddy
//
//  Settings page shown inside the Clicky chat window when the user
//  clicks the gear icon. Organised into tabs so settings can grow
//  without becoming a wall of scroll. Current tabs:
//
//  • Profile — name, goals, additional context (injected into Claude's system prompt)
//  • General — model, TTS voice, STT speech, API keys
//

import MacAutomation
import SwiftUI
import UniformTypeIdentifiers

/// Which tab is currently active in the settings view.
private enum SettingsTab: String, CaseIterable {
    case general  = "General"
    case profile  = "Profile"
    case learning = "Learning"
}

struct ChatSettingsView: View {
    @ObservedObject var companionManager: CompanionManager
    let onDismiss: () -> Void

    @State private var selectedTab: SettingsTab = .general
    /// Collapsed by default so the Actions section doesn't dominate the
    /// General tab — the 8+ toggles are power-user territory, not something
    /// you need to see every time you open Settings.
    @State private var isActionsSectionExpanded: Bool = false
    /// Expanded by default — this section is how users discover that Clicky
    /// can read Claude Code aloud and how to wire the Stop hook.
    @State private var isIntegrationsSectionExpanded: Bool = true
    @State private var isIntegrationsSetupInstructionsExpanded: Bool = false
    @State private var integrationsCopyFeedback: String = ""

    // General tab state
    @State private var apiKeyInput = ""
    @State private var isAPIKeyVisible = false

    // Profile tab state — pre-filled from companionManager.userProfile on appear
    @State private var profileNickname: String = ""
    @State private var profileGoals: String = ""
    @State private var profileAdditionalContext: String = ""
    @State private var profileSaveStatus: String = ""

    // Learning tab state
    @State private var learningEntries: [LearningEntry] = []
    @State private var learningDeleteConfirmID: UUID? = nil
    @State private var exportStatus: String = ""

    var body: some View {
        VStack(spacing: 0) {
            tabBar

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 24) {
                    switch selectedTab {
                    case .profile:
                        profileTab
                    case .learning:
                        learningTab
                    case .general:
                        generalTab
                    }
                }
                .padding(24)
            }
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
            let savedProfile = companionManager.userProfile
            profileNickname = savedProfile.nickname
            profileGoals = savedProfile.goals
            profileAdditionalContext = savedProfile.additionalContext
            learningEntries = companionManager.learningLogStore.loadAllEntries().reversed()
        }
        .alert(
            "Apple Notes Permission",
            isPresented: $companionManager.showAppleNotesPermissionAlert
        ) {
            Button("Open System Settings") {
                companionManager.openAutomationSettings()
            }
            Button("Cancel", role: .cancel) {
                companionManager.isAppleNotesEnabled = false
                UserDefaults.standard.set(false, forKey: "isAppleNotesEnabled")
            }
        } message: {
            Text("Clicky needs Automation permission to create notes in Apple Notes.\n\nOpen System Settings → Privacy & Security → Automation, find Clicky, and enable Notes.")
        }
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(SettingsTab.allCases, id: \.self) { tab in
                tabBarButton(tab: tab)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(DS.Colors.surface1)
        .overlay(
            Rectangle()
                .fill(DS.Colors.borderSubtle)
                .frame(height: 0.5),
            alignment: .bottom
        )
    }

    private func tabBarButton(tab: SettingsTab) -> some View {
        let isSelected = selectedTab == tab
        return Button(action: { selectedTab = tab }) {
            Text(tab.rawValue)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isSelected ? Color.white.opacity(0.1) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    // MARK: - Profile Tab

    private var profileTab: some View {
        settingsSection(title: "Profile") {
            VStack(alignment: .leading, spacing: 12) {
                settingsHint("Tell Clicky who you are. This gets added to every conversation so responses are always personalized to you.")

                // Name
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

                // Save
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            profileSaveStatus = ""
        }
    }

    /// A styled multi-line text editor. SwiftUI's TextEditor has no placeholder support,
    /// so we layer a greyed-out hint label behind it when the binding is empty.
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
                .tint(DS.Colors.textSecondary)
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

    // MARK: - Learning Tab

    private var learningTab: some View {
        VStack(spacing: 16) {
            settingsSection(title: "Learning Log") {
                VStack(alignment: .leading, spacing: 10) {
                    settingsHint("Clicky silently logs every topic you learn about. Use this to review, quiz yourself, or see what you haven't covered yet.")

                    if learningEntries.isEmpty {
                        settingsHint("No entries yet — start asking Clicky questions about any app or topic.")
                            .padding(.top, 4)
                    } else {
                        // Group by app
                        let grouped = Dictionary(grouping: learningEntries) { $0.app }
                        let sortedApps = grouped.keys.sorted()

                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(sortedApps, id: \.self) { app in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(app)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundColor(DS.Colors.textSecondary)

                                    ForEach(grouped[app] ?? []) { entry in
                                        learningEntryRow(entry)
                                    }
                                }
                            }
                        }

                        // Clear all + Export row
                        HStack(spacing: 8) {
                            if !exportStatus.isEmpty {
                                Text(exportStatus)
                                    .font(.system(size: 11))
                                    .foregroundColor(DS.Colors.textTertiary)
                            }
                            Spacer()
                            Button(action: exportLearningLogAsMarkdown) {
                                Text("Export .md")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(DS.Colors.textSecondary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(
                                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                                            .fill(Color.white.opacity(0.06))
                                    )
                            }
                            .buttonStyle(.plain)
                            .pointerCursor()

                            Button(action: {
                                companionManager.learningLogStore.clearAllEntries()
                                learningEntries = []
                            }) {
                                Text("Clear all")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(DS.Colors.textTertiary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(
                                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                                            .fill(Color.white.opacity(0.06))
                                    )
                            }
                            .buttonStyle(.plain)
                            .pointerCursor()
                        }
                        .padding(.top, 4)
                    }
                }
            }

            settingsSection(title: "Daily Review") {
                VStack(alignment: .leading, spacing: 10) {
                    settingsHint("Get a morning nudge with yesterday's topics and a prompt to quiz yourself. Claude generates the questions fresh — no pre-cooked flashcards.")

                    HStack {
                        Text("Daily review notification")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(DS.Colors.textSecondary)
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { companionManager.isDailyReviewEnabled },
                            set: { companionManager.setDailyReviewEnabled($0) }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .tint(DS.Colors.accent)
                        .scaleEffect(0.8)
                    }

                    if companionManager.isDailyReviewEnabled {
                        HStack {
                            Text("Notify at")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(DS.Colors.textSecondary)
                            Spacer()
                            // Hour picker: 6am–10pm in readable labels
                            Picker("", selection: Binding(
                                get: { companionManager.dailyReviewHour },
                                set: { companionManager.setDailyReviewHour($0) }
                            )) {
                                ForEach(reviewHourOptions, id: \.hour) { option in
                                    Text(option.label).tag(option.hour)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .frame(width: 90)
                        }
                    }
                }
            }

            settingsSection(title: "Quiz") {
                VStack(alignment: .leading, spacing: 8) {
                    settingsHint("Ask Clicky to quiz you on what you've learned. Type in the chat window:")

                    VStack(alignment: .leading, spacing: 4) {
                        quizExampleRow("Quiz me on DaVinci Resolve")
                        quizExampleRow("What did I learn this week?")
                        quizExampleRow("What haven't I covered in Swift yet?")
                        quizExampleRow("Summarize my Resolve knowledge")
                    }
                }
            }
        }
    }

    /// Hour options shown in the daily review time picker. Range: 6am–10pm.
    private var reviewHourOptions: [(hour: Int, label: String)] {
        let formatter = DateFormatter()
        formatter.dateFormat = "h a"
        return (6...22).map { hour in
            var components = DateComponents()
            components.hour = hour
            components.minute = 0
            let date = Calendar.current.date(from: components) ?? Date()
            return (hour: hour, label: formatter.string(from: date))
        }
    }

    /// Opens an NSSavePanel and writes the learning log as a Markdown file.
    private func exportLearningLogAsMarkdown() {
        let savePanel = NSSavePanel()
        savePanel.title = "Export Learning Log"
        savePanel.nameFieldStringValue = "clicky-learning-log.md"
        savePanel.allowedContentTypes = [.plainText]
        savePanel.canCreateDirectories = true

        guard savePanel.runModal() == .OK, let url = savePanel.url else { return }

        let markdownContent = companionManager.learningLogStore.exportAsMarkdown()
        do {
            try markdownContent.write(to: url, atomically: true, encoding: .utf8)
            exportStatus = "Exported"
            // Clear the status after 3 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                exportStatus = ""
            }
        } catch {
            exportStatus = "Export failed"
            print("⚠️ Learning log export failed: \(error)")
        }
    }

    private func learningEntryRow(_ entry: LearningEntry) -> some View {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .none

        return HStack {
            Text(entry.topic)
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textPrimary)
            Spacer()
            Text(formatter.string(from: entry.date))
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
            Button(action: {
                companionManager.learningLogStore.deleteEntry(withID: entry.id)
                learningEntries = companionManager.learningLogStore.loadAllEntries().reversed()
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
    }

    private func quizExampleRow(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(DS.Colors.textTertiary)
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(DS.Colors.textSecondary)
        }
    }

    // MARK: - General Tab

    private var generalTab: some View {
        Group {
            modelSection
            voiceSection
            speechSection
            voiceDisplaySection
            readingSection
            integrationsSection
            actionsSection
        }
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
        case "lmstudio": return "lmstudio"
        case "local":    return "local"
        default:         return "anthropic"
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

    // MARK: - Voice

    private var voiceDisplaySection: some View {
        settingsSection(title: "Voice Display") {
            actionToggleRow(
                label: "Show streaming text during voice",
                hint: "Response appears as a bubble while Claude is generating — before TTS starts",
                isOn: Binding(
                    get: { companionManager.isVoiceStreamingTextEnabled },
                    set: { companionManager.setVoiceStreamingTextEnabled($0) }
                )
            )
        }
    }

    // MARK: - Reading (⌃⇧L read-aloud sub-settings)

    /// In-window equivalent of the menu-bar panel's Reading section — the two
    /// UIs must stay in parity so users don't have to remember which settings
    /// live where. Controls: where read-aloud starts (top vs cursor), whether
    /// a screenshot is captured for the chat replay card, and the on-screen
    /// highlight style while speaking.
    private var readingSection: some View {
        settingsSection(title: "Reading (⌃⇧L)") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Read mode")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)

                    Spacer()

                    HStack(spacing: 0) {
                        readAloudModeOptionButton(label: "From Top", modeID: "frontmostFromTop")
                        readAloudModeOptionButton(label: "From Cursor", modeID: "fromCursorPoint")
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

                HStack {
                    Text("Capture screenshot on ⌃⇧L")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)

                    Spacer()

                    Toggle("", isOn: Binding(
                        get: { companionManager.isReadAloudScreenshotCaptureEnabled },
                        set: { companionManager.setReadAloudScreenshotCaptureEnabled($0) }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .tint(DS.Colors.accent)
                    .scaleEffect(0.8)
                }

                HStack {
                    Text("Highlight style")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)

                    Spacer()

                    HStack(spacing: 0) {
                        readAloudHighlightStyleOptionButton(label: "Highlight", styleID: "highlight")
                        readAloudHighlightStyleOptionButton(label: "Underline", styleID: "underline")
                        readAloudHighlightStyleOptionButton(label: "Popover", styleID: "popover")
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
            }
        }
    }

    private func readAloudModeOptionButton(label: String, modeID: String) -> some View {
        let isSelected = companionManager.readAloudReadMode == modeID
        return Button(action: {
            companionManager.setReadAloudReadMode(modeID)
        }) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? DS.Colors.accent.opacity(0.4) : Color.clear)
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private func readAloudHighlightStyleOptionButton(label: String, styleID: String) -> some View {
        let isSelected = companionManager.readAloudHighlightStyle == styleID
        return Button(action: {
            companionManager.setReadAloudHighlightStyle(styleID)
        }) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? DS.Colors.accent.opacity(0.4) : Color.clear)
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    // MARK: - Actions

    /// Toggles that control which action tags Claude is allowed to execute.
    /// Each toggle maps directly to a flag in CompanionManager that gates the
    /// corresponding executor — turning one off means the tag is still stripped
    /// from the response text, but the action is never performed.
    private var actionsSection: some View {
        collapsibleSettingsSection(
            title: "Actions",
            isExpanded: $isActionsSectionExpanded,
            masterToggle: Binding(
                get: { companionManager.isActionsMasterEnabled },
                set: { companionManager.setActionsMasterEnabled($0) }
            )
        ) {
            VStack(spacing: 0) {
                actionToggleRow(
                    label: "Track learning topics",
                    hint: "Log [LOG:] tags to the Learning tab",
                    isOn: Binding(
                        get: { companionManager.isLearningLogEnabled },
                        set: { companionManager.setLearningLogEnabled($0) }
                    )
                )

                Divider()
                    .background(DS.Colors.borderSubtle)
                    .padding(.vertical, 2)

                actionToggleRow(
                    label: "Open URLs and apps",
                    hint: "Execute [OPEN:] tags via NSWorkspace",
                    isOn: Binding(
                        get: { companionManager.isOpenActionEnabled },
                        set: { companionManager.setOpenActionEnabled($0) }
                    )
                )

                Divider()
                    .background(DS.Colors.borderSubtle)
                    .padding(.vertical, 2)

                actionToggleRow(
                    label: "Run Apple Shortcuts",
                    hint: "Execute [SHORTCUT:] tags via the shortcuts CLI",
                    isOn: Binding(
                        get: { companionManager.isShortcutActionEnabled },
                        set: { companionManager.setShortcutActionEnabled($0) }
                    )
                )

                Divider()
                    .background(DS.Colors.borderSubtle)
                    .padding(.vertical, 2)

                actionToggleRow(
                    label: "Create reminders",
                    hint: "Execute [REMIND:] tags via EventKit — requires Reminders permission",
                    isOn: Binding(
                        get: { companionManager.isRemindActionEnabled },
                        set: { companionManager.setRemindActionEnabled($0) }
                    )
                )

                Divider()
                    .background(DS.Colors.borderSubtle)
                    .padding(.vertical, 2)

                actionToggleRow(
                    label: "Control music",
                    hint: "Execute [MUSIC:] tags — works with Spotify, Apple Music, YouTube, etc.",
                    isOn: Binding(
                        get: { companionManager.isMusicActionEnabled },
                        set: { companionManager.setMusicActionEnabled($0) }
                    )
                )

                Divider()
                    .background(DS.Colors.borderSubtle)
                    .padding(.vertical, 2)

                actionToggleRow(
                    label: "Click UI elements",
                    hint: "Execute [CLICK:] tags — simulates mouse clicks at screen coordinates (voice only)",
                    isOn: Binding(
                        get: { companionManager.isClickActionEnabled },
                        set: { companionManager.setClickActionEnabled($0) }
                    )
                )

                Divider()
                    .background(DS.Colors.borderSubtle)
                    .padding(.vertical, 2)

                actionToggleRow(
                    label: "Read aloud (⌃⇧L)",
                    hint: "Reads the frontmost app's visible text via the selected TTS provider. Tap again to stop.",
                    isOn: Binding(
                        get: { companionManager.isReadAloudShortcutEnabled },
                        set: { companionManager.setReadAloudShortcutEnabled($0) }
                    )
                )

                Divider()
                    .background(DS.Colors.borderSubtle)
                    .padding(.vertical, 2)

                actionToggleRow(
                    label: "Save to Apple Notes",
                    hint: "Create notes via [NOTE:] tags — requires Automation permission for Notes",
                    isOn: Binding(
                        get: { companionManager.isAppleNotesEnabled },
                        set: { companionManager.setAppleNotesEnabled($0) }
                    )
                )

                Divider()
                    .background(DS.Colors.borderSubtle)
                    .padding(.vertical, 2)

                actionToggleRow(
                    label: "Save to Obsidian",
                    hint: "Create markdown notes in your Obsidian vault via [NOTE:] tags",
                    isOn: Binding(
                        get: { companionManager.isObsidianEnabled },
                        set: { companionManager.setObsidianEnabled($0) }
                    )
                )

                // Show vault picker when Obsidian is enabled
                if companionManager.isObsidianEnabled {
                    obsidianVaultPicker
                }
            }
        }
    }

    /// Picker for selecting which Obsidian vault to save notes into.
    private var obsidianVaultPicker: some View {
        let vaults = ObsidianManager.listVaults()
        return HStack(spacing: 8) {
            Text("Vault")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)

            Picker("", selection: Binding(
                get: { companionManager.selectedObsidianVaultPath },
                set: { companionManager.setSelectedObsidianVaultPath($0) }
            )) {
                if vaults.isEmpty {
                    Text("No vaults found").tag("")
                }
                ForEach(vaults, id: \.path) { vault in
                    Text(vault.name).tag(vault.path)
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)
        }
        .padding(.leading, 4)
        .padding(.vertical, 2)
    }

    private func actionToggleRow(label: String, hint: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
            }

            Spacer()

            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(DS.Colors.accent)
                .scaleEffect(0.8)
        }
        .padding(.vertical, 6)
    }

    // MARK: - Integrations

    /// Exposes the Claude Code Stop-hook TTS feature. Toggle controls
    /// whether Clicky acts on `clicky://speak` URLs; the nested disclosure
    /// shows a copy-pastable prompt the user drops into Claude Code to
    /// install the hook. Mirrors SuperUtter's Integrations layout so users
    /// coming from there find the same mental model.
    private var integrationsSection: some View {
        collapsibleSettingsSection(
            title: "Integrations",
            isExpanded: $isIntegrationsSectionExpanded,
            masterToggle: Binding(
                get: { companionManager.isAutoPlayClaudeCodeEnabled },
                set: { companionManager.setAutoPlayClaudeCodeEnabled($0) }
            )
        ) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Auto-Play Claude Code")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                    Text("Automatically reads Claude Code responses aloud via the selected TTS voice. Requires a one-time Stop hook in ~/.claude/settings.json — use the setup prompt below.")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider().background(DS.Colors.borderSubtle)

                integrationsSetupInstructions
            }
        }
    }

    /// Collapsible disclosure that shows the copy-paste prompt for wiring
    /// the Claude Code Stop hook. The user drops this into a Claude Code
    /// session and Claude creates the script + registers the hook.
    private var integrationsSetupInstructions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: {
                withAnimation(.easeOut(duration: 0.18)) {
                    isIntegrationsSetupInstructionsExpanded.toggle()
                }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: isIntegrationsSetupInstructionsExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(DS.Colors.textSecondary)
                        .frame(width: 10)
                    Text("Setup instructions")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                }
            }
            .buttonStyle(.plain)
            .pointerCursor()

            if isIntegrationsSetupInstructionsExpanded {
                Text("Copy the prompt below and paste it into Claude Code. It will create the hook script, make it executable, and register it in ~/.claude/settings.json for you.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                ScrollView(.vertical) {
                    Text(ChatSettingsView.clickyClaudeCodeSetupPrompt)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(DS.Colors.textSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(maxHeight: 220)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.black.opacity(0.25))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                )

                HStack {
                    Spacer()
                    if !integrationsCopyFeedback.isEmpty {
                        Text(integrationsCopyFeedback)
                            .font(.system(size: 11))
                            .foregroundColor(DS.Colors.textTertiary)
                            .transition(.opacity)
                    }
                    Button(action: copyClickyClaudeCodeSetupPrompt) {
                        HStack(spacing: 6) {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 11, weight: .medium))
                            Text("Copy prompt")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.white.opacity(0.06))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                        )
                        .foregroundColor(DS.Colors.textPrimary)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }
        }
    }

    private func copyClickyClaudeCodeSetupPrompt() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(ChatSettingsView.clickyClaudeCodeSetupPrompt, forType: .string)
        withAnimation(.easeOut(duration: 0.2)) {
            integrationsCopyFeedback = "Copied"
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation(.easeOut(duration: 0.2)) {
                integrationsCopyFeedback = ""
            }
        }
    }

    /// Prompt the user pastes into Claude Code to install the Stop hook.
    /// Kept as a static constant so it's easy to update in one place when
    /// the hook script changes.
    static let clickyClaudeCodeSetupPrompt: String = """
    Set up the Clicky TTS integration for Claude Code on macOS.

    1. Create the directory `~/.claude/hooks/` if it doesn't exist, then write this file to `~/.claude/hooks/clicky-speak.sh`:

    ```bash
    #!/bin/bash
    # Clicky Claude Code TTS hook
    # Reads the last assistant message from the Stop-hook payload and pipes
    # it to the Clicky app via the clicky://speak?file=<path> URL scheme.
    INPUT=$(cat)
    TEXT=$(HOOK_INPUT="$INPUT" python3 <<'PY'
    import json, os, sys
    try:
        payload = json.loads(os.environ.get("HOOK_INPUT", ""))
    except Exception:
        sys.exit(0)
    def from_transcript(path):
        try:
            with open(path, "r") as f:
                lines = f.readlines()
        except OSError:
            return ""
        for line in reversed(lines):
            try:
                entry = json.loads(line)
            except Exception:
                continue
            if entry.get("type") != "assistant":
                continue
            content = (entry.get("message") or {}).get("content") or []
            parts = [c.get("text", "") for c in content if c.get("type") == "text"]
            return "\\n\\n".join(p for p in parts if p).strip()
        return ""
    text = (payload.get("last_assistant_message") or "").strip()
    if not text:
        text = from_transcript(payload.get("transcript_path", "")).strip()
    if text:
        if len(text) > 50000:
            text = text[:50000] + "... (truncated)"
        print(text)
    PY
    )
    [ -z "$TEXT" ] && exit 0
    TMPFILE="/tmp/clicky-$(uuidgen).txt"
    printf '%s' "$TEXT" > "$TMPFILE"
    open "clicky://speak?file=$TMPFILE" 2>/dev/null
    exit 0
    ```

    2. Make it executable: `chmod +x ~/.claude/hooks/clicky-speak.sh`

    3. Register the hook in `~/.claude/settings.json`. If the file already exists, merge — do NOT overwrite existing keys or other hooks. Add this entry to `hooks.Stop` (creating the arrays if missing):

    ```json
    {
      "hooks": {
        "Stop": [
          {
            "hooks": [
              {
                "type": "command",
                "command": "bash ~/.claude/hooks/clicky-speak.sh"
              }
            ]
          }
        ]
      }
    }
    ```

    Notes:
    - The `Stop` entry uses the nested `hooks` array format. There is no `async` field — Claude Code runs hooks directly.
    - No restart needed. The hook fires on the next assistant response.
    - Clicky must be running with "Auto-Play Claude Code" enabled in Settings → General → Integrations.
    """

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

    /// Collapsible variant of `settingsSection` — the title row becomes a
    /// disclosure button with a chevron, and an optional master toggle lets
    /// the user turn the whole section off without expanding it. Content is
    /// hidden (not just collapsed) when `isExpanded` is false so the section
    /// genuinely takes less vertical space.
    private func collapsibleSettingsSection<Content: View>(
        title: String,
        isExpanded: Binding<Bool>,
        masterToggle: Binding<Bool>? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button(action: {
                    withAnimation(.easeOut(duration: 0.18)) {
                        isExpanded.wrappedValue.toggle()
                    }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: isExpanded.wrappedValue ? "chevron.down" : "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Colors.textSecondary)
                            .frame(width: 10)
                        Text(title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(DS.Colors.textPrimary)
                    }
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }

                Spacer()

                if let masterToggle {
                    Toggle("", isOn: masterToggle)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .tint(DS.Colors.accent)
                        .scaleEffect(0.8)
                }
            }

            if isExpanded.wrappedValue {
                content()
                    .opacity(masterToggle?.wrappedValue == false ? 0.45 : 1.0)
                    .disabled(masterToggle?.wrappedValue == false)
            }
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
