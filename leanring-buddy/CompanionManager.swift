//
//  CompanionManager.swift
//  leanring-buddy
//
//  Central state manager for the companion voice mode. Owns the push-to-talk
//  pipeline (dictation manager + global shortcut monitor + overlay) and
//  exposes observable voice state for the panel UI.
//

import AVFoundation
import Combine
import Foundation
import PostHog
import ScreenCaptureKit
import SwiftUI

enum CompanionVoiceState {
    case idle
    case listening
    case processing
    case responding
}

@MainActor
final class CompanionManager: ObservableObject {
    @Published private(set) var voiceState: CompanionVoiceState = .idle
    @Published private(set) var lastTranscript: String?
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasScreenContentPermission = false

    /// Screen location (global AppKit coords) of a detected UI element the
    /// buddy should fly to and point at. Parsed from Claude's response;
    /// observed by BlueCursorView to trigger the flight animation.
    @Published var detectedElementScreenLocation: CGPoint?
    /// The display frame (global AppKit coords) of the screen the detected
    /// element is on, so BlueCursorView knows which screen overlay should animate.
    @Published var detectedElementDisplayFrame: CGRect?
    /// Custom speech bubble text for the pointing animation. When set,
    /// BlueCursorView uses this instead of a random pointer phrase.
    @Published var detectedElementBubbleText: String?

    // MARK: - Onboarding Video State (shared across all screen overlays)

    @Published var onboardingVideoPlayer: AVPlayer?
    @Published var showOnboardingVideo: Bool = false
    @Published var onboardingVideoOpacity: Double = 0.0
    private var onboardingVideoEndObserver: NSObjectProtocol?
    private var onboardingDemoTimeObserver: Any?

    // MARK: - Onboarding Prompt Bubble

    /// Text streamed character-by-character on the cursor after the onboarding video ends.
    @Published var onboardingPromptText: String = ""
    @Published var onboardingPromptOpacity: Double = 0.0
    @Published var showOnboardingPrompt: Bool = false

    // MARK: - Onboarding Music

    private var onboardingMusicPlayer: AVAudioPlayer?
    private var onboardingMusicFadeTimer: Timer?

    let buddyDictationManager = BuddyDictationManager()
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let overlayWindowManager = OverlayWindowManager()
    /// Floating panel that shows Claude's response text streaming in real-time
    /// during voice interactions (when isVoiceStreamingTextEnabled is on).
    let responseOverlayManager = CompanionResponseOverlayManager()
    /// Persists conversations and screenshots to Application Support.
    let conversationStore = ConversationStore()
    /// Persists the user's learning log to Application Support/Clicky/learning/log.json.
    let learningLogStore = LearningLogStore()
    /// Schedules and manages the daily learning review notification.
    let dailyReviewScheduler = DailyReviewScheduler()

    // MARK: - Frontmost app tracking

    /// The name of the last non-Clicky app the user was working in.
    /// Updated via an NSWorkspace notification observer so it's always
    /// current by the time a voice or chat request is made.
    /// Injected into the system prompt so Claude knows the user's context
    /// without the user having to say "I'm in Xcode" every time.
    private(set) var lastKnownFrontmostNonClickyAppName: String?

    /// Token returned by addObserver — retained so the observation stays active
    /// for the lifetime of CompanionManager.
    private var frontmostAppObserverToken: Any?
    // Response text is now displayed inline on the cursor overlay via
    // streamingResponseText, so no separate response overlay manager is needed.

    /// Base URL for the Cloudflare Worker proxy. Used when no direct API key is set.
    private static let workerBaseURL = "https://your-worker-name.your-subdomain.workers.dev"

    /// User-provided Anthropic API key for direct mode (no Worker needed).
    /// When set, Claude requests go straight to api.anthropic.com.
    /// Persisted to Keychain so it survives app restarts and stays secure.
    @Published var anthropicAPIKey: String = KeychainHelper.load(forKey: "anthropicAPIKey")

    func setAnthropicAPIKey(_ key: String) {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        anthropicAPIKey = trimmedKey
        KeychainHelper.save(trimmedKey, forKey: "anthropicAPIKey")
        // Recreate the Claude client to use direct mode (or fall back to proxy)
        claudeAPI = makeClaudeAPI()
    }

    /// Whether the app is using a direct Anthropic API key instead of the Worker proxy.
    var isUsingDirectAPIKey: Bool {
        !anthropicAPIKey.isEmpty
    }

    private func makeClaudeAPI() -> ClaudeAPI {
        if !anthropicAPIKey.isEmpty {
            return ClaudeAPI(apiKey: anthropicAPIKey, model: selectedModel)
        } else {
            return ClaudeAPI(proxyURL: "\(Self.workerBaseURL)/chat", model: selectedModel)
        }
    }

    private lazy var claudeAPI: ClaudeAPI = {
        return makeClaudeAPI()
    }()

    private lazy var elevenLabsTTSClient: ElevenLabsTTSClient = {
        return ElevenLabsTTSClient(proxyURL: "\(Self.workerBaseURL)/tts")
    }()

    private lazy var supertonicTTSClient: SupertonicTTSClient = {
        return SupertonicTTSClient()
    }()

    /// On-device LLM client via Apple Intelligence (FoundationModels).
    /// Text-only, no vision. Requires macOS 26+.
    private lazy var apfelAPI: ApfelAPI = {
        return ApfelAPI()
    }()

    /// OpenAI-compatible API client for LM Studio (local vision models).
    /// Talks to LM Studio's /v1/chat/completions endpoint at 127.0.0.1:1234.
    private lazy var lmStudioAPI: OpenAIAPI = {
        return OpenAIAPI(apiKey: lmStudioAPIKey, model: selectedLMStudioModel)
    }()

    /// Whether the selected model is the local on-device Apple Intelligence model.
    var isLocalModel: Bool {
        selectedModel == "local"
    }

    /// Whether the selected model is a local LM Studio model.
    var isLMStudioModel: Bool {
        selectedModel == "lmstudio"
    }

    /// Whether Apple Intelligence is available for local text-only mode.
    var isAppleIntelligenceAvailable: Bool {
        apfelAPI.isAvailable
    }

    // MARK: - LM Studio Configuration

    /// User-provided LM Studio API key (optional — many local setups don't require one).
    /// Persisted to Keychain so it survives app restarts and stays secure.
    @Published var lmStudioAPIKey: String = KeychainHelper.load(forKey: "lmStudioAPIKey")

    func setLMStudioAPIKey(_ key: String) {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        lmStudioAPIKey = trimmedKey
        KeychainHelper.save(trimmedKey, forKey: "lmStudioAPIKey")
        lmStudioAPI.apiKey = trimmedKey
    }

    /// The model ID selected from LM Studio's available models.
    /// Persisted separately from the Claude model selection.
    @Published var selectedLMStudioModel: String = UserDefaults.standard.string(forKey: "selectedLMStudioModel") ?? ""

    func setSelectedLMStudioModel(_ model: String) {
        selectedLMStudioModel = model
        UserDefaults.standard.set(model, forKey: "selectedLMStudioModel")
        lmStudioAPI.model = model
    }

    /// Models discovered from LM Studio's /v1/models endpoint.
    @Published var availableLMStudioModels: [String] = []

    /// Whether to extract on-screen text via Accessibility API or Vision OCR before
    /// sending a query to local models (Apple Intelligence) or LM Studio.
    ///
    /// When enabled, the extracted text is prepended to the user's spoken prompt so
    /// that text-only models (Apple Intelligence) gain screen context and LM Studio
    /// models with weak vision can still read what's on screen without depending
    /// entirely on image encoding. Defaults to true. Persisted to UserDefaults.
    @Published var isOCRExtractionEnabled: Bool = UserDefaults.standard.object(forKey: "isOCRExtractionEnabled") as? Bool ?? true

    func setOCRExtractionEnabled(_ enabled: Bool) {
        isOCRExtractionEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isOCRExtractionEnabled")
    }

    // MARK: - Voice streaming text

    /// When enabled, Claude's response text streams into a floating bubble near the
    /// cursor during voice interactions — the user sees the response being generated
    /// live instead of staring at the spinner until TTS starts playing.
    @Published var isVoiceStreamingTextEnabled: Bool = UserDefaults.standard.object(forKey: "isVoiceStreamingTextEnabled") as? Bool ?? true

    func setVoiceStreamingTextEnabled(_ enabled: Bool) {
        isVoiceStreamingTextEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isVoiceStreamingTextEnabled")
        if !enabled {
            responseOverlayManager.hideOverlay()
        }
    }

    // MARK: - Action tag toggles

    /// Whether Claude can silently log topics to the learning store via [LOG:] tags.
    /// Toggling off stops new entries from being written; existing entries are untouched.
    @Published var isLearningLogEnabled: Bool = UserDefaults.standard.object(forKey: "isLearningLogEnabled") as? Bool ?? true

    func setLearningLogEnabled(_ enabled: Bool) {
        isLearningLogEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isLearningLogEnabled")
    }

    /// Whether Claude can open URLs and launch apps via [OPEN:] tags.
    @Published var isOpenActionEnabled: Bool = UserDefaults.standard.object(forKey: "isOpenActionEnabled") as? Bool ?? true

    func setOpenActionEnabled(_ enabled: Bool) {
        isOpenActionEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isOpenActionEnabled")
    }

    /// Whether Claude can run Apple Shortcuts by name via [SHORTCUT:] tags.
    @Published var isShortcutActionEnabled: Bool = UserDefaults.standard.object(forKey: "isShortcutActionEnabled") as? Bool ?? true

    func setShortcutActionEnabled(_ enabled: Bool) {
        isShortcutActionEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isShortcutActionEnabled")
    }

    /// Whether Claude can create macOS reminders via [REMIND:] tags.
    @Published var isRemindActionEnabled: Bool = UserDefaults.standard.object(forKey: "isRemindActionEnabled") as? Bool ?? true

    func setRemindActionEnabled(_ enabled: Bool) {
        isRemindActionEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isRemindActionEnabled")
    }

    /// Whether Claude can control music playback via [MUSIC:] tags.
    /// Uses media key simulation — works with Spotify, Apple Music, YouTube, etc.
    @Published var isMusicActionEnabled: Bool = UserDefaults.standard.object(forKey: "isMusicActionEnabled") as? Bool ?? true

    func setMusicActionEnabled(_ enabled: Bool) {
        isMusicActionEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isMusicActionEnabled")
    }

    /// Whether Claude can simulate left-clicks at screen coordinates via [CLICK:] tags.
    /// Requires the accessibility permission already granted for push-to-talk.
    @Published var isClickActionEnabled: Bool = UserDefaults.standard.object(forKey: "isClickActionEnabled") as? Bool ?? true

    func setClickActionEnabled(_ enabled: Bool) {
        isClickActionEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isClickActionEnabled")
    }

    // MARK: - Daily review notification settings

    /// Whether the daily learning review notification is enabled.
    @Published var isDailyReviewEnabled: Bool = UserDefaults.standard.object(forKey: "isDailyReviewEnabled") as? Bool ?? false

    /// The hour of day (0–23) at which the daily review notification fires. Default: 9am.
    @Published var dailyReviewHour: Int = UserDefaults.standard.object(forKey: "dailyReviewHour") as? Int ?? 9

    func setDailyReviewEnabled(_ enabled: Bool) {
        isDailyReviewEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isDailyReviewEnabled")
        Task { await rescheduleDailyReviewNotification() }
    }

    func setDailyReviewHour(_ hour: Int) {
        dailyReviewHour = hour
        UserDefaults.standard.set(hour, forKey: "dailyReviewHour")
        if isDailyReviewEnabled {
            Task { await rescheduleDailyReviewNotification() }
        }
    }

    /// Cancels any existing daily review notification and schedules a fresh
    /// one if the feature is enabled and there are recent learning entries.
    func rescheduleDailyReviewNotification() async {
        guard isDailyReviewEnabled else {
            dailyReviewScheduler.cancelDailyReview()
            return
        }
        let permissionGranted = await dailyReviewScheduler.requestPermissionIfNeeded()
        guard permissionGranted else {
            print("⚠️ DailyReview: notification permission denied")
            return
        }
        let recentEntries = learningLogStore.loadRecentEntries(withinDays: 1)
        await dailyReviewScheduler.scheduleDailyReview(atHour: dailyReviewHour, recentTopics: recentEntries)
    }

    /// Queries LM Studio's local /v1/models endpoint and populates the model dropdown.
    func fetchAvailableLMStudioModels() {
        guard let url = URL(string: "http://127.0.0.1:1234/v1/models") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        if !lmStudioAPIKey.isEmpty {
            request.setValue("Bearer \(lmStudioAPIKey)", forHTTPHeaderField: "Authorization")
        }

        Task {
            do {
                let (data, _) = try await URLSession.shared.data(for: request)
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let dataArray = json["data"] as? [[String: Any]] {
                    var models = dataArray.compactMap { $0["id"] as? String }
                        .filter { modelID in
                            // Filter out SHA hashes (unloaded models) and speech tokenizer sub-models.
                            // Readable model IDs contain a "/" (e.g. "google/gemma-4-e4b") or
                            // a hyphen-separated name (e.g. "text-embedding-nomic-embed-text-v1.5").
                            let looksLikeHash = modelID.range(of: "^[0-9a-f]{20,}$", options: .regularExpression) != nil
                            let isSpeechTokenizer = modelID.contains("/speech_tokenizer")
                            return !looksLikeHash && !isSpeechTokenizer
                        }
                    models.sort()
                    self.availableLMStudioModels = models
                    // Auto-select first model if none selected yet
                    if selectedLMStudioModel.isEmpty, let firstModel = models.first {
                        setSelectedLMStudioModel(firstModel)
                    }
                }
            } catch {
                // LM Studio unreachable — clear the list so it drops from the model cycler
                if !self.availableLMStudioModels.isEmpty {
                    print("[LMStudio] Lost connection, clearing model list")
                    self.availableLMStudioModels = []
                }
            }
        }
    }

    private var lmStudioPollingTask: Task<Void, Never>?

    /// Polls LM Studio's /v1/models endpoint every 30 seconds so the model
    /// cycler (⌃M) picks up LM Studio whenever it starts or stops.
    private func startLMStudioModelPolling() {
        lmStudioPollingTask?.cancel()
        lmStudioPollingTask = Task { @MainActor in
            while !Task.isCancelled {
                fetchAvailableLMStudioModels()
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }

    /// Which TTS backend to use for voice responses. "elevenlabs" or "supertonic".
    /// Persisted to UserDefaults so the choice survives app restarts.
    @Published var selectedTTSProvider: String = UserDefaults.standard.string(forKey: "selectedTTSProvider") ?? "elevenlabs"

    func setSelectedTTSProvider(_ provider: String) {
        stopActiveTTSPlayback()
        selectedTTSProvider = provider
        UserDefaults.standard.set(provider, forKey: "selectedTTSProvider")
    }

    /// Which STT backend to use for voice transcription. "assemblyai" or "parakeet".
    /// Persisted to UserDefaults so the choice survives app restarts.
    @Published var selectedSTTProvider: String = UserDefaults.standard.string(forKey: "selectedSTTProvider") ?? "assemblyai"

    func setSelectedSTTProvider(_ provider: String) {
        selectedSTTProvider = provider
        UserDefaults.standard.set(provider, forKey: "selectedSTTProvider")

        let providerInstance: any BuddyTranscriptionProvider
        switch provider {
        case "parakeet":
            providerInstance = BuddyTranscriptionProviderFactory.makeProvider(
                for: .parakeet)
        default:
            providerInstance = BuddyTranscriptionProviderFactory.makeProvider(
                for: .assemblyAI)
        }
        buddyDictationManager.switchTranscriptionProvider(to: providerInstance)
    }

    /// Conversation history so Claude remembers prior exchanges within a session.
    /// Each entry is the user's transcript and Claude's response.
    private var conversationHistory: [(userTranscript: String, assistantResponse: String)] = []

    /// The currently running AI response task, if any. Cancelled when the user
    /// speaks again so a new response can begin immediately.
    private var currentResponseTask: Task<Void, Never>?

    private var shortcutTransitionCancellable: AnyCancellable?
    private var modelCycleCancellable: AnyCancellable?
    private var voiceStateCancellable: AnyCancellable?
    private var audioPowerCancellable: AnyCancellable?
    private var accessibilityCheckTimer: Timer?
    private var pendingKeyboardShortcutStartTask: Task<Void, Never>?
    /// Scheduled hide for transient cursor mode — cancelled if the user
    /// speaks again before the delay elapses.
    private var transientHideTask: Task<Void, Never>?

    /// True when all three required permissions (accessibility, screen recording,
    /// microphone) are granted. Used by the panel to show a single "all good" state.
    var allPermissionsGranted: Bool {
        hasAccessibilityPermission && hasScreenRecordingPermission && hasMicrophonePermission && hasScreenContentPermission
    }

    /// Whether the blue cursor overlay is currently visible on screen.
    /// Used by the panel to show accurate status text ("Active" vs "Ready").
    @Published private(set) var isOverlayVisible: Bool = false

    /// All conversations, sorted by most recent activity. Drives the sidebar.
    @Published var conversations: [Conversation] = []

    /// The ID of the currently active conversation. Messages shown in the
    /// chat window belong to this conversation.
    @Published var activeConversationID: UUID?

    /// All messages in the active conversation, ordered oldest-first.
    /// Includes both voice (push-to-talk) and text (typed) exchanges so the
    /// chat window shows the full session history regardless of input method.
    @Published var chatMessages: [ChatMessage] = []

    /// True while a text-chat message is being sent and Claude is streaming a
    /// response. Used by ChatView to disable the send button and show the
    /// typing indicator.
    @Published private(set) var isSendingChatMessage: Bool = false

    /// The Claude model used for voice responses. Persisted to UserDefaults.
    @Published var selectedModel: String = UserDefaults.standard.string(forKey: "selectedClaudeModel") ?? "claude-sonnet-4-6"

    /// Set briefly after a model cycle to show the icon badge on the cursor overlay.
    /// Cleared automatically after the display duration.
    @Published var modelSwitchBadgeModelID: String? = nil
    private var modelSwitchBadgeDismissTask: Task<Void, Never>?

    /// The actual model identifier to store in message metadata. For Claude models
    /// this is the model ID (e.g. "claude-sonnet-4-6"). For LM Studio, this is the
    /// real model name (e.g. "gemma-4-2b") so the JSON log is useful for debugging.
    var resolvedModelIDForMessages: String {
        switch selectedModel {
        case "lmstudio":
            return selectedLMStudioModel.isEmpty ? "lmstudio" : selectedLMStudioModel
        default:
            return selectedModel
        }
    }

    /// The last-used Anthropic model. Persisted so the ⌃M cycler remembers
    /// whether you prefer Sonnet or Opus. Defaults to Sonnet (cheaper).
    @Published var lastUsedAnthropicModel: String = UserDefaults.standard.string(forKey: "lastUsedAnthropicModel") ?? "claude-sonnet-4-6"

    func setSelectedModel(_ model: String) {
        selectedModel = model
        UserDefaults.standard.set(model, forKey: "selectedClaudeModel")
        // Only update claudeAPI.model for actual Claude model IDs
        if model != "local" && model != "lmstudio" {
            claudeAPI.model = model
            // Remember which Anthropic model was last used
            lastUsedAnthropicModel = model
            UserDefaults.standard.set(model, forKey: "lastUsedAnthropicModel")
        }
    }

    /// Models the user can actually use right now, based on API key availability
    /// and service reachability. Used by the keyboard shortcut model cycler.
    /// Shows one Anthropic slot (last-used model, defaulting to Sonnet).
    var availableModels: [String] {
        var models: [String] = []
        // Anthropic: one slot using the last-used Claude model (Sonnet or Opus)
        if isUsingDirectAPIKey || !Self.workerBaseURL.contains("your-worker-name") {
            models.append(lastUsedAnthropicModel)
        }
        // LM Studio: available if at least one model was discovered
        if !availableLMStudioModels.isEmpty {
            models.append("lmstudio")
        }
        // Apple Intelligence: available if macOS 26+ and FoundationModels present
        if isAppleIntelligenceAvailable {
            models.append("local")
        }
        return models
    }

    /// Cycles to the next available model in the list. Wraps around at the end.
    /// Briefly shows a model icon badge on the Clicky cursor overlay.
    func cycleToNextModel() {
        let models = availableModels
        print("[ModelCycler] cycleToNextModel called — available: \(models), current: \(selectedModel)")
        guard models.count > 1 else {
            print("[ModelCycler] Only \(models.count) model(s) available, skipping cycle")
            return
        }
        if let currentIndex = models.firstIndex(of: selectedModel) {
            let nextIndex = (currentIndex + 1) % models.count
            print("[ModelCycler] Cycling \(selectedModel) → \(models[nextIndex])")
            setSelectedModel(models[nextIndex])
        } else {
            print("[ModelCycler] Current model not in available list, jumping to \(models[0])")
            setSelectedModel(models[0])
        }
        showModelSwitchBadge()
    }

    /// Shows the model icon badge on the cursor overlay, then auto-dismisses.
    private func showModelSwitchBadge() {
        modelSwitchBadgeDismissTask?.cancel()
        modelSwitchBadgeModelID = selectedModel
        print("[ModelCycler] Badge shown: \(selectedModel)")
        modelSwitchBadgeDismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            modelSwitchBadgeModelID = nil
        }
    }

    /// User preference for whether the Clicky cursor should be shown.
    /// When toggled off, the overlay is hidden and push-to-talk is disabled.
    /// Persisted to UserDefaults so the choice survives app restarts.
    @Published var isClickyCursorEnabled: Bool = UserDefaults.standard.object(forKey: "isClickyCursorEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isClickyCursorEnabled")

    func setClickyCursorEnabled(_ enabled: Bool) {
        isClickyCursorEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isClickyCursorEnabled")
        transientHideTask?.cancel()
        transientHideTask = nil

        if enabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        } else {
            overlayWindowManager.hideOverlay()
            isOverlayVisible = false
        }
    }

    // MARK: - User Profile

    /// The user's personal context card (name, goals, extra notes). When filled in,
    /// this gets prepended to every Claude system prompt so responses are personalized
    /// and goal-aware from the very first message.
    @Published var userProfile: UserProfile = UserProfile.load()

    func saveUserProfile(_ updatedProfile: UserProfile) {
        userProfile = updatedProfile
        updatedProfile.save()
    }

    /// Prepends the user profile block and current context (active app, now playing)
    /// to a base system prompt. Each piece is omitted when not available.
    private func buildSystemPromptWithContext(_ baseSystemPrompt: String) -> String {
        var prefixParts: [String] = []

        if userProfile.hasAnyContent {
            prefixParts.append(userProfile.buildSystemPromptSection())
        }

        // Inject which app the user is currently working in so Claude speaks
        // the right language (Resolve terms, Xcode shortcuts, etc.) without
        // the user having to mention the app in every message.
        if let appName = lastKnownFrontmostNonClickyAppName {
            prefixParts.append("current app: \(appName)")
        }

        // Inject the currently playing track so Claude can answer "what's this song?"
        // or act on "skip this" / "pause" without needing a screenshot.
        if let nowPlaying = MusicController.currentlyPlayingDescription() {
            prefixParts.append("currently playing: \(nowPlaying)")
        }

        guard !prefixParts.isEmpty else { return baseSystemPrompt }
        return prefixParts.joined(separator: "\n") + "\n" + baseSystemPrompt
    }

    /// Whether the user has completed onboarding at least once. Persisted
    /// to UserDefaults so the Start button only appears on first launch.
    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    /// Whether the user has submitted their email during onboarding.
    @Published var hasSubmittedEmail: Bool = UserDefaults.standard.bool(forKey: "hasSubmittedEmail")

    /// Submits the user's email to FormSpark and identifies them in PostHog.
    func submitEmail(_ email: String) {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty else { return }

        hasSubmittedEmail = true
        UserDefaults.standard.set(true, forKey: "hasSubmittedEmail")

        // Identify user in PostHog
        PostHogSDK.shared.identify(trimmedEmail, userProperties: [
            "email": trimmedEmail
        ])

        // Submit to FormSpark
        Task {
            var request = URLRequest(url: URL(string: "https://submit-form.com/RWbGJxmIs")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["email": trimmedEmail])
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    func start() {
        // Migrate API keys from UserDefaults to Keychain (one-time, safe to call every launch)
        KeychainHelper.migrateFromUserDefaultsIfNeeded(userDefaultsKey: "anthropicAPIKey", keychainKey: "anthropicAPIKey")
        KeychainHelper.migrateFromUserDefaultsIfNeeded(userDefaultsKey: "lmStudioAPIKey", keychainKey: "lmStudioAPIKey")
        // Re-read from Keychain in case migration just happened
        anthropicAPIKey = KeychainHelper.load(forKey: "anthropicAPIKey")
        lmStudioAPIKey = KeychainHelper.load(forKey: "lmStudioAPIKey")

        // Migrate legacy single-history format if needed, then load conversations
        conversationStore.migrateFromLegacyHistoryIfNeeded()
        conversations = conversationStore.loadConversationsIndex()

        // Always start a fresh conversation on launch so voice/text exchanges
        // don't pile into the previous session. Old conversations stay in the
        // sidebar for reference.
        createNewConversation()

        refreshAllPermissions()
        print("🔑 Clicky start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), onboarded: \(hasCompletedOnboarding)")
        startPermissionPolling()
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindShortcutTransitions()

        // Restore the user's saved STT provider from UserDefaults so it
        // survives app restarts (BuddyDictationManager defaults to Info.plist).
        if selectedSTTProvider == "parakeet" {
            let parakeetProvider = BuddyTranscriptionProviderFactory.makeProvider(for: .parakeet)
            buddyDictationManager.switchTranscriptionProvider(to: parakeetProvider)
        }

        // Eagerly touch the Claude API so its TLS warmup handshake completes
        // well before the onboarding demo fires at ~40s into the video.
        _ = claudeAPI

        // Discover LM Studio models at startup and re-check periodically so
        // the model cycler picks up LM Studio whenever it starts or stops.
        startLMStudioModelPolling()

        // If the user already completed onboarding AND all permissions are
        // still granted, show the cursor overlay immediately. If permissions
        // were revoked (e.g. signing change), don't show the cursor — the
        // panel will show the permissions UI instead.
        if hasCompletedOnboarding && allPermissionsGranted && isClickyCursorEnabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }

        startFrontmostAppTracking()

        // Reschedule the daily review notification in the background so it
        // fires at the right time on first launch and after the app restarts.
        if isDailyReviewEnabled {
            Task { await rescheduleDailyReviewNotification() }
        }
    }

    /// Starts observing NSWorkspace application-activation notifications.
    /// Whenever the user switches to a non-Clicky app, we store its name so
    /// the system prompt can include "the user is currently working in X".
    private func startFrontmostAppTracking() {
        // Capture the current frontmost app immediately so the first voice
        // request doesn't have nil context if the user hasn't switched apps yet.
        let currentApp = NSWorkspace.shared.frontmostApplication
        if currentApp?.bundleIdentifier != Bundle.main.bundleIdentifier {
            lastKnownFrontmostNonClickyAppName = currentApp?.localizedName
        }

        // Observe future app switches. The block runs on .main so it's safe
        // to update the stored name directly (CompanionManager is @MainActor).
        frontmostAppObserverToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            let activatedApp = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            // Only update when the activated app is not Clicky itself —
            // we want to know what the user was working on, not that they opened Clicky.
            guard activatedApp?.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
            self.lastKnownFrontmostNonClickyAppName = activatedApp?.localizedName
        }
    }

    // MARK: - Conversation Management

    /// Switches to a different conversation, saving the current one first.
    /// Rebuilds the API conversation history from the loaded messages so
    /// Claude has context within the new conversation.
    func switchToConversation(_ conversationID: UUID) {
        guard conversationID != activeConversationID else { return }
        guard !isSendingChatMessage else { return }

        // Save current conversation in the background so it doesn't block the
        // switch. Capture the messages and ID before mutating state.
        let previousMessages = chatMessages
        let previousID = activeConversationID
        if let previousID {
            Task.detached(priority: .utility) { [conversationStore, conversations] in
                conversationStore.saveMessages(previousMessages, for: previousID)
                conversationStore.saveConversationsIndex(conversations)
            }
        }

        activeConversationID = conversationID
        chatMessages = conversationStore.loadMessages(for: conversationID)

        // Rebuild the in-memory API context from the loaded messages so Claude
        // has conversational context within this conversation (not cross-conversation)
        rebuildConversationHistoryFromChatMessages()
    }

    /// Creates a new empty conversation, prepends it to the sidebar list,
    /// and makes it active.
    func createNewConversation() {
        // Save current conversation before switching away
        saveActiveConversationToDisk()

        let newConversation = conversationStore.createConversation()
        conversations.insert(newConversation, at: 0)
        conversationStore.saveConversationsIndex(conversations)

        activeConversationID = newConversation.id
        chatMessages = []
        conversationHistory = []
    }

    /// Deletes a conversation from disk and the sidebar list. If the deleted
    /// conversation was active, switches to the most recent remaining one
    /// or creates a new empty conversation.
    func deleteConversation(_ conversationID: UUID) {
        conversationStore.deleteConversation(id: conversationID)
        conversations.removeAll { $0.id == conversationID }
        conversationStore.saveConversationsIndex(conversations)

        if conversationID == activeConversationID {
            if let mostRecent = conversations.first {
                activeConversationID = nil // Force switchToConversation to proceed
                switchToConversation(mostRecent.id)
            } else {
                activeConversationID = nil
                createNewConversation()
            }
        }
    }

    /// Persists the current active conversation's messages and updates
    /// its metadata in the index.
    private func saveActiveConversationToDisk() {
        guard let activeID = activeConversationID else { return }
        conversationStore.saveMessages(chatMessages, for: activeID)
        updateConversationMetadata(for: activeID)
    }

    /// Updates the metadata (updatedAt, messageCount) for a conversation
    /// in the index and saves the index to disk.
    private func updateConversationMetadata(for conversationID: UUID) {
        guard let conversationIndex = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        conversations[conversationIndex].updatedAt = Date()
        conversations[conversationIndex].messageCount = chatMessages.count
        conversationStore.saveConversationsIndex(conversations)
    }

    /// Auto-titles a conversation from the first user message if the title
    /// is still the default "New Chat".
    private func autoTitleActiveConversationIfNeeded(from userText: String) {
        guard let activeID = activeConversationID,
              let conversationIndex = conversations.firstIndex(where: { $0.id == activeID }),
              conversations[conversationIndex].title == "New Chat"
        else { return }

        let trimmedText = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        // Truncate to ~40 characters at a word boundary
        let title: String
        if trimmedText.count <= 40 {
            title = trimmedText
        } else {
            let prefix = String(trimmedText.prefix(40))
            if let lastSpace = prefix.lastIndex(of: " ") {
                title = String(prefix[prefix.startIndex..<lastSpace])
            } else {
                title = prefix
            }
        }

        conversations[conversationIndex].title = title
    }

    /// Rebuilds the in-memory `conversationHistory` (used for Claude API context)
    /// from the current `chatMessages`. Takes the last 10 user-assistant pairs.
    private func rebuildConversationHistoryFromChatMessages() {
        conversationHistory = []

        var pairIndex = 0
        while pairIndex < chatMessages.count {
            let message = chatMessages[pairIndex]
            if message.role == .user,
               pairIndex + 1 < chatMessages.count,
               chatMessages[pairIndex + 1].role == .assistant {
                conversationHistory.append((
                    userTranscript: message.content,
                    assistantResponse: chatMessages[pairIndex + 1].content
                ))
                pairIndex += 2
            } else {
                pairIndex += 1
            }
        }

        // Keep only the last 10 exchanges
        if conversationHistory.count > 10 {
            conversationHistory.removeFirst(conversationHistory.count - 10)
        }
    }

    /// Called by BlueCursorView after the buddy finishes its pointing
    /// animation and returns to cursor-following mode.
    /// Triggers the onboarding sequence — dismisses the panel and restarts
    /// the overlay so the welcome animation and intro video play.
    func triggerOnboarding() {
        // Post notification so the panel manager can dismiss the panel
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

        // Mark onboarding as completed so the Start button won't appear
        // again on future launches — the cursor will auto-show instead
        hasCompletedOnboarding = true

        ClickyAnalytics.trackOnboardingStarted()

        // Play Besaid theme at 60% volume, fade out after 1m 30s
        startOnboardingMusic()

        // Show the overlay for the first time — isFirstAppearance triggers
        // the welcome animation and onboarding video
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    /// Replays the onboarding experience from the "Watch Onboarding Again"
    /// footer link. Same flow as triggerOnboarding but the cursor overlay
    /// is already visible so we just restart the welcome animation and video.
    func replayOnboarding() {
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
        ClickyAnalytics.trackOnboardingReplayed()
        startOnboardingMusic()
        // Tear down any existing overlays and recreate with isFirstAppearance = true
        overlayWindowManager.hasShownOverlayBefore = false
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    private func stopOnboardingMusic() {
        onboardingMusicFadeTimer?.invalidate()
        onboardingMusicFadeTimer = nil
        onboardingMusicPlayer?.stop()
        onboardingMusicPlayer = nil
    }

    private func startOnboardingMusic() {
        stopOnboardingMusic()
        guard let musicURL = Bundle.main.url(forResource: "ff", withExtension: "mp3") else {
            print("⚠️ Clicky: ff.mp3 not found in bundle")
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: musicURL)
            player.volume = 0.3
            player.play()
            self.onboardingMusicPlayer = player

            // After 1m 30s, fade the music out over 3s
            onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: 90.0, repeats: false) { [weak self] _ in
                self?.fadeOutOnboardingMusic()
            }
        } catch {
            print("⚠️ Clicky: Failed to play onboarding music: \(error)")
        }
    }

    private func fadeOutOnboardingMusic() {
        guard let player = onboardingMusicPlayer else { return }

        let fadeSteps = 30
        let fadeDuration: Double = 3.0
        let stepInterval = fadeDuration / Double(fadeSteps)
        let volumeDecrement = player.volume / Float(fadeSteps)
        var stepsRemaining = fadeSteps

        onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { [weak self] timer in
            stepsRemaining -= 1
            player.volume -= volumeDecrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.stop()
                self?.onboardingMusicPlayer = nil
                self?.onboardingMusicFadeTimer = nil
            }
        }
    }

    func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
    }

    func stop() {
        globalPushToTalkShortcutMonitor.stop()
        buddyDictationManager.cancelCurrentDictation()
        overlayWindowManager.hideOverlay()
        transientHideTask?.cancel()

        currentResponseTask?.cancel()
        currentResponseTask = nil
        elevenLabsTTSClient.stopPlayback()
        supertonicTTSClient.stopPlayback()
        shortcutTransitionCancellable?.cancel()
        voiceStateCancellable?.cancel()
        audioPowerCancellable?.cancel()
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil
    }

    func refreshAllPermissions() {
        let previouslyHadAccessibility = hasAccessibilityPermission
        let previouslyHadScreenRecording = hasScreenRecordingPermission
        let previouslyHadMicrophone = hasMicrophonePermission
        let previouslyHadAll = allPermissionsGranted

        let currentlyHasAccessibility = WindowPositionManager.hasAccessibilityPermission()
        hasAccessibilityPermission = currentlyHasAccessibility

        if currentlyHasAccessibility {
            globalPushToTalkShortcutMonitor.start()
        } else {
            globalPushToTalkShortcutMonitor.stop()
        }

        hasScreenRecordingPermission = WindowPositionManager.hasScreenRecordingPermission()

        let micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        hasMicrophonePermission = micAuthStatus == .authorized

        // Debug: log permission state on changes
        if previouslyHadAccessibility != hasAccessibilityPermission
            || previouslyHadScreenRecording != hasScreenRecordingPermission
            || previouslyHadMicrophone != hasMicrophonePermission {
            print("🔑 Permissions — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission)")
        }

        // Track individual permission grants as they happen
        if !previouslyHadAccessibility && hasAccessibilityPermission {
            ClickyAnalytics.trackPermissionGranted(permission: "accessibility")
        }
        if !previouslyHadScreenRecording && hasScreenRecordingPermission {
            ClickyAnalytics.trackPermissionGranted(permission: "screen_recording")
        }
        if !previouslyHadMicrophone && hasMicrophonePermission {
            ClickyAnalytics.trackPermissionGranted(permission: "microphone")
        }
        // Screen content permission is persisted — once the user has approved the
        // SCShareableContent picker, we don't need to re-check it.
        if !hasScreenContentPermission {
            hasScreenContentPermission = UserDefaults.standard.bool(forKey: "hasScreenContentPermission")
        }

        if !previouslyHadAll && allPermissionsGranted {
            ClickyAnalytics.trackAllPermissionsGranted()
        }
    }

    /// Triggers the macOS screen content picker by performing a dummy
    /// screenshot capture. Once the user approves, we persist the grant
    /// so they're never asked again during onboarding.
    @Published private(set) var isRequestingScreenContent = false

    func requestScreenContentPermission() {
        guard !isRequestingScreenContent else { return }
        isRequestingScreenContent = true
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    await MainActor.run { isRequestingScreenContent = false }
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = 320
                config.height = 240
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                // Verify the capture actually returned real content — a 0x0 or
                // fully-empty image means the user denied the prompt.
                let didCapture = image.width > 0 && image.height > 0
                print("🔑 Screen content capture result — width: \(image.width), height: \(image.height), didCapture: \(didCapture)")
                await MainActor.run {
                    isRequestingScreenContent = false
                    guard didCapture else { return }
                    hasScreenContentPermission = true
                    UserDefaults.standard.set(true, forKey: "hasScreenContentPermission")
                    ClickyAnalytics.trackPermissionGranted(permission: "screen_content")

                    // If onboarding was already completed, show the cursor overlay now
                    if hasCompletedOnboarding && allPermissionsGranted && !isOverlayVisible && isClickyCursorEnabled {
                        overlayWindowManager.hasShownOverlayBefore = true
                        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                        isOverlayVisible = true
                    }
                }
            } catch {
                print("⚠️ Screen content permission request failed: \(error)")
                await MainActor.run { isRequestingScreenContent = false }
            }
        }
    }

    // MARK: - Private

    /// Triggers the system microphone prompt if the user has never been asked.
    /// Once granted/denied the status sticks and polling picks it up.
    private func promptForMicrophoneIfNotDetermined() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor [weak self] in
                self?.hasMicrophonePermission = granted
            }
        }
    }

    /// Polls all permissions frequently so the UI updates live after the
    /// user grants them in System Settings. Screen Recording is the exception —
    /// macOS requires an app restart for that one to take effect.
    private func startPermissionPolling() {
        accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }
    }

    private func bindAudioPowerLevel() {
        audioPowerCancellable = buddyDictationManager.$currentAudioPowerLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] powerLevel in
                self?.currentAudioPowerLevel = powerLevel
            }
    }

    private func bindVoiceStateObservation() {
        voiceStateCancellable = buddyDictationManager.$isRecordingFromKeyboardShortcut
            .combineLatest(
                buddyDictationManager.$isFinalizingTranscript,
                buddyDictationManager.$isPreparingToRecord
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording, isFinalizing, isPreparing in
                guard let self else { return }
                // Don't override .responding — the AI response pipeline
                // manages that state directly until streaming finishes.
                guard self.voiceState != .responding else { return }

                if isFinalizing {
                    self.voiceState = .processing
                } else if isRecording {
                    self.voiceState = .listening
                } else if isPreparing {
                    self.voiceState = .processing
                } else {
                    self.voiceState = .idle
                    // If the user pressed and released the hotkey without
                    // saying anything, no response task runs — schedule the
                    // transient hide here so the overlay doesn't get stuck.
                    // Only do this when no response is in flight, otherwise
                    // the brief idle gap between recording and processing
                    // would prematurely hide the overlay.
                    if self.currentResponseTask == nil {
                        self.scheduleTransientHideIfNeeded()
                    }
                }
            }
    }

    private func bindShortcutTransitions() {
        shortcutTransitionCancellable = globalPushToTalkShortcutMonitor
            .shortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleShortcutTransition(transition)
            }

        modelCycleCancellable = globalPushToTalkShortcutMonitor
            .modelCyclePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.cycleToNextModel()
            }
    }

    private func handleShortcutTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            guard !buddyDictationManager.isDictationInProgress else { return }
            // Don't register push-to-talk while the onboarding video is playing
            guard !showOnboardingVideo else { return }

            // Cancel any pending transient hide so the overlay stays visible
            transientHideTask?.cancel()
            transientHideTask = nil

            // If the cursor is hidden, bring it back transiently for this interaction
            if !isClickyCursorEnabled && !isOverlayVisible {
                overlayWindowManager.hasShownOverlayBefore = true
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }

            // Dismiss the menu bar panel so it doesn't cover the screen
            NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

            // Cancel any in-progress response and TTS from a previous utterance
            currentResponseTask?.cancel()
            stopActiveTTSPlayback()
            clearDetectedElementLocation()

            // Dismiss the onboarding prompt if it's showing
            if showOnboardingPrompt {
                withAnimation(.easeOut(duration: 0.3)) {
                    onboardingPromptOpacity = 0.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    self.showOnboardingPrompt = false
                    self.onboardingPromptText = ""
                }
            }
    

            ClickyAnalytics.trackPushToTalkStarted()

            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = Task {
                await buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                    currentDraftText: "",
                    updateDraftText: { _ in
                        // Partial transcripts are hidden (waveform-only UI)
                    },
                    submitDraftText: { [weak self] finalTranscript in
                        self?.lastTranscript = finalTranscript
                        print("🗣️ Companion received transcript: \(finalTranscript)")
                        ClickyAnalytics.trackUserMessageSent(transcript: finalTranscript)
                        self?.sendTranscriptToClaudeWithScreenshot(transcript: finalTranscript)
                    }
                )
            }
        case .released:
            // Cancel the pending start task in case the user released the shortcut
            // before the async startPushToTalk had a chance to begin recording.
            // Without this, a quick press-and-release drops the release event and
            // leaves the waveform overlay stuck on screen indefinitely.
            ClickyAnalytics.trackPushToTalkReleased()
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = nil
            buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
        case .none:
            break
        }
    }

    // MARK: - Companion Prompt

    /// Base voice system prompt. User profile is prepended at call time via
    /// `companionVoiceResponseSystemPrompt` (the instance computed var below).
    private static let companionVoiceResponseBaseSystemPrompt = """
    you're clicky, a friendly always-on companion that lives in the user's menu bar. the user just spoke to you via push-to-talk and you can see their screen(s). your reply will be spoken aloud via text-to-speech, so write the way you'd actually talk. this is an ongoing conversation — you remember everything they've said before.

    rules:
    - always respond in the same language the user spoke in. if they speak french, reply in french. if they speak english, reply in english. match their language exactly.
    - default to one or two sentences. be direct and dense. BUT if the user asks you to explain more, go deeper, or elaborate, then go all out — give a thorough, detailed explanation with no length limit.
    - all lowercase, casual, warm. no emojis.
    - write for the ear, not the eye. short sentences. no lists, bullet points, markdown, or formatting — just natural speech.
    - don't use abbreviations or symbols that sound weird read aloud. write "for example" not "e.g.", spell out small numbers.
    - if the user's question relates to what's on their screen, reference specific things you see.
    - if the screenshot doesn't seem relevant to their question, just answer the question directly.
    - you can help with anything — coding, writing, general knowledge, brainstorming.
    - never say "simply" or "just".
    - don't read out code verbatim. describe what the code does or what needs to change conversationally.
    - focus on giving a thorough, useful explanation. don't end with simple yes/no questions like "want me to explain more?" or "should i show you?" — those are dead ends that force the user to just say yes.
    - instead, when it fits naturally, end by planting a seed — mention something bigger or more ambitious they could try, a related concept that goes deeper, or a next-level technique that builds on what you just explained. make it something worth coming back for, not a question they'd just nod to. it's okay to not end with anything extra if the answer is complete on its own.
    - if you receive multiple screen images, the one labeled "primary focus" is where the cursor is — prioritize that one but reference others if relevant.

    element pointing:
    you have a small blue triangle cursor that can fly to and point at things on screen. use it whenever pointing would genuinely help the user — if they're asking how to do something, looking for a menu, trying to find a button, or need help navigating an app, point at the relevant element. err on the side of pointing rather than not pointing, because it makes your help way more useful and concrete.

    don't point at things when it would be pointless — like if the user asks a general knowledge question, or the conversation has nothing to do with what's on screen, or you'd just be pointing at something obvious they're already looking at. but if there's a specific UI element, menu, button, or area on screen that's relevant to what you're helping with, point at it.

    when you point, append a coordinate tag at the very end of your response, AFTER your spoken text. the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. the origin (0,0) is the top-left corner of the image. x increases rightward, y increases downward.

    format: [POINT:x,y:label] where x,y are integer pixel coordinates in the screenshot's coordinate space, and label is a short 1-3 word description of the element (like "search bar" or "save button"). if the element is on the cursor's screen you can omit the screen number. if the element is on a DIFFERENT screen, append :screenN where N is the screen number from the image label (e.g. :screen2). this is important — without the screen number, the cursor will point at the wrong place.

    if pointing wouldn't help, append [POINT:none].

    examples:
    - user asks how to color grade in final cut: "you'll want to open the color inspector — it's right up in the top right area of the toolbar. click that and you'll get all the color wheels and curves. [POINT:1100,42:color inspector]"
    - user asks what html is: "html stands for hypertext markup language, it's basically the skeleton of every web page. curious how it connects to the css you're looking at? [POINT:none]"
    - user asks how to commit in xcode: "see that source control menu up top? click that and hit commit, or you can use command option c as a shortcut. [POINT:285,11:source control]"
    - element is on screen 2 (not where cursor is): "that's over on your other monitor — see the terminal window? [POINT:400,300:terminal:screen2]"

    saving notes and logging learning:
    when the user asks to save something, take a note, or remember something for later, append a note block after your spoken text (after the [POINT:...] tag is fine):

    [NOTE:short descriptive title]
    note content here — use markdown since this is saved, not spoken. include date context if useful. personalise the explanation to the user's level and goals from their profile.
    [/NOTE]

    whenever you explain a concept, answer a how-to question, or teach the user something about an app or technology, also append a silent learning log tag:

    [LOG:app-or-topic-area:specific concept]

    examples:
    - user asks about color wheels in DaVinci Resolve: [LOG:DaVinci Resolve:color wheels]
    - user asks about Swift closures: [LOG:Swift:closures]
    - user asks how to commit in Xcode: [LOG:Xcode:git commit]

    keep the app and concept short (3-5 words each). use [LOG:] even when you don't create a [NOTE:].

    opening apps and urls:
    when the user asks to open something, append: [OPEN:url-or-app-name]
    examples: [OPEN:https://docs.blackmagicdesign.com] or [OPEN:Xcode]

    running shortcuts:
    when the user asks to run an automation or control an app via a shortcut, append: [SHORTCUT:exact shortcut name]

    creating reminders:
    when the user asks to be reminded of something, append: [REMIND:reminder text:when (e.g. tomorrow 9am)]

    music control:
    when the user asks to play, pause, skip, go back, or control music, append: [MUSIC:action]
    valid actions: play, pause, toggle, next, prev
    examples: [MUSIC:next] or [MUSIC:pause]
    works system-wide — whichever app is currently playing (Spotify, Apple Music, YouTube, etc.) will respond.
    the "currently playing" context above tells you what's active so you can confirm it in your reply.

    clicking ui elements:
    when the user asks you to click something on screen, or when clicking would complete their request (e.g. "render this", "save the file", "click that button"), append: [CLICK:x,y:label]
    coordinates are in the same screenshot pixel space as [POINT:] — top-left origin, same image dimensions.
    if the element is on a different screen, append :screenN (e.g. [CLICK:400,200:render button:screen2]).
    the cursor will fly to the target for visual confirmation, then the click fires.
    only use [CLICK:] when you're confident about the element's location from the screenshot. never guess.
    you can combine [CLICK:] and [POINT:] in the same response — [CLICK:] for the element to interact with, [POINT:] for a different element to highlight.
    example: "i'll hit render for you — [CLICK:1200,680:start render]"

    all action tags are stripped from what gets spoken — never mention them in your spoken response.
    """

    /// Voice system prompt with user profile + frontmost app context prepended.
    /// Evaluated at call time so it always reflects the current app.
    private var companionVoiceResponseSystemPrompt: String {
        buildSystemPromptWithContext(Self.companionVoiceResponseBaseSystemPrompt)
    }

    /// Base chat system prompt. User profile is prepended at call time via
    /// `companionChatSystemPrompt` (the instance computed var below).
    private static let companionChatBaseSystemPrompt = """
    you're clicky, a friendly always-on companion that lives in the user's menu bar. \
    the user is chatting with you via text in the clicky chat window. \
    this is an ongoing conversation — you remember everything said before in this session, \
    including any voice exchanges the user had earlier.

    rules:
    - always respond in the same language the user writes in. if they write in french, reply in french.
    - you can give longer, more detailed responses than in voice mode — text doesn't have a length penalty.
    - use markdown formatting when it helps: **bold** for emphasis, `code` for inline code, \
    ```language blocks for multi-line code, bullet lists for steps. don't over-format casual replies.
    - be direct and clear. avoid filler phrases like "certainly!" or "great question!".
    - never say "simply" or "just".
    - you can help with anything — coding, writing, analysis, general knowledge, brainstorming.
    - don't end with a yes/no question like "want me to explain more?" — those are dead ends. \
    if it fits, mention something bigger they could explore next.

    saving notes and logging learning:
    when the user asks to save a note, remember something, or create a note, append a note block at the end of your response:

    [NOTE:short descriptive title]
    note content here — markdown is fine. personalise to the user's level and goals from their profile.
    [/NOTE]

    you can briefly confirm in your response that you saved the note (e.g. "saved to Apple Notes"). \
    the [NOTE:...]...[/NOTE] block is automatically stripped before display.

    whenever you explain a concept or answer a how-to question, also append a silent learning log tag:

    [LOG:app-or-topic-area:specific concept]

    examples: [LOG:DaVinci Resolve:color wheels] or [LOG:Swift:closures] or [LOG:Xcode:git commit]

    opening apps and urls:
    when the user asks to open something, append: [OPEN:url-or-app-name]

    running shortcuts:
    when the user asks to run an automation, append: [SHORTCUT:exact shortcut name]

    creating reminders:
    when the user asks to be reminded of something, append: [REMIND:reminder text:when]

    music control:
    when the user asks to play, pause, skip, or control music, append: [MUSIC:action]
    valid actions: play, pause, toggle, next, prev
    the "currently playing" context above tells you what's active so you can reference it.

    all action tags are stripped automatically — never mention them in your response text.
    """

    /// Chat system prompt with user profile + frontmost app context prepended.
    /// Evaluated at call time so it always reflects the current app.
    private var companionChatSystemPrompt: String {
        buildSystemPromptWithContext(Self.companionChatBaseSystemPrompt)
    }

    // MARK: - Text Chat Pipeline

    /// Sends a typed message from the chat window to Claude and streams the response
    /// in-place into chatMessages. Unlike the voice pipeline, this does not use TTS,
    /// does not capture a screenshot, and does not trigger cursor pointing — it's a
    /// pure text exchange that shares the same conversation history as voice mode.
    func sendChatTextMessage(_ userText: String) {
        guard !userText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let userMessage = ChatMessage(role: .user, content: userText, source: .text)
        chatMessages.append(userMessage)

        // Append an empty assistant placeholder that streaming will fill in.
        // The chat view shows a typing indicator while this message has no content.
        let assistantPlaceholder = ChatMessage(role: .assistant, content: "", source: .text, modelID: resolvedModelIDForMessages)
        chatMessages.append(assistantPlaceholder)
        let assistantPlaceholderID = assistantPlaceholder.id

        isSendingChatMessage = true

        Task {
            defer { isSendingChatMessage = false }

            do {
                let responseStartTime = Date()

                let historyForAPI = conversationHistory.map { entry in
                    (userPlaceholder: entry.userTranscript, assistantResponse: entry.assistantResponse)
                }

                let (fullResponseText, _) = try await claudeAPI.analyzeImageStreaming(
                    images: [],
                    systemPrompt: companionChatSystemPrompt,
                    conversationHistory: historyForAPI,
                    userPrompt: userText,
                    onTextChunk: { [weak self] accumulatedText in
                        guard let self else { return }
                        // analyzeImageStreaming delivers accumulated text (not just the new chunk),
                        // so we set rather than append to keep the content accurate.
                        if let messageIndex = self.chatMessages.firstIndex(where: { $0.id == assistantPlaceholderID }) {
                            self.chatMessages[messageIndex].content = accumulatedText
                        }
                    }
                )

                let responseDuration = Date().timeIntervalSince(responseStartTime)

                // Strip NOTE tags first (they contain multi-line content that the action
                // parser doesn't need to see), then run all remaining action tags through
                // the unified ActionTagParser in one pass.
                let chatNoteResult = Self.parseAndStripNoteTags(from: fullResponseText)
                for note in chatNoteResult.notes {
                    createAppleNote(title: note.title, content: note.content)
                }

                let chatActionResult = ActionTagParser.parse(from: chatNoteResult.textWithNotesStripped)
                let responseTextForDisplay = chatActionResult.cleanedText

                // Execute all extracted actions in the background
                executeActionTags(chatActionResult, noteTitle: chatNoteResult.notes.first?.title)

                // Ensure the final content is set with all tags stripped (the last onTextChunk
                // may have fired before stripping, so always update the final content here)
                if let messageIndex = chatMessages.firstIndex(where: { $0.id == assistantPlaceholderID }) {
                    chatMessages[messageIndex].content = responseTextForDisplay
                    chatMessages[messageIndex].responseDurationSeconds = responseDuration
                }

                // Share this exchange with the conversation history so future requests
                // (voice or text) have context for what was already discussed.
                // Store the display text (with NOTE tags stripped) rather than the raw
                // response so NOTE blocks don't pollute future conversation context.
                conversationHistory.append((
                    userTranscript: userText,
                    assistantResponse: responseTextForDisplay
                ))
                if conversationHistory.count > 10 {
                    conversationHistory.removeFirst(conversationHistory.count - 10)
                }

                print("🧠 Chat message sent. Conversation history: \(conversationHistory.count) exchanges")

                // Auto-title the conversation from the first user message
                autoTitleActiveConversationIfNeeded(from: userText)

                // Persist the updated message list and metadata to disk
                if let activeID = activeConversationID {
                    conversationStore.saveMessages(chatMessages, for: activeID)
                    updateConversationMetadata(for: activeID)
                }

            } catch {
                // Replace the empty placeholder with a user-visible error so the
                // chat doesn't silently show a blank bubble
                if let messageIndex = chatMessages.firstIndex(where: { $0.id == assistantPlaceholderID }) {
                    chatMessages[messageIndex].content = "Something went wrong — please try again."
                }
                print("⚠️ Chat text error: \(error)")
            }
        }
    }

    // MARK: - AI Response Pipeline

    /// Captures a screenshot, sends it along with the transcript to Claude,
    /// and plays the response aloud via ElevenLabs TTS. The cursor stays in
    /// the spinner/processing state until TTS audio begins playing.
    /// Claude's response may include a [POINT:x,y:label] tag which triggers
    /// the buddy to fly to that element on screen.
    private func sendTranscriptToClaudeWithScreenshot(transcript: String) {
        currentResponseTask?.cancel()
        elevenLabsTTSClient.stopPlayback()

        currentResponseTask = Task {
            voiceState = .processing

            // Show the streaming text overlay if the setting is on.
            // This lets the user read the response being generated while
            // the spinner is still running — before TTS starts playing.
            if isVoiceStreamingTextEnabled {
                responseOverlayManager.showOverlayAndBeginStreaming()
            }

            do {
                let fullResponseText: String
                var screenCaptures: [CompanionScreenCapture] = []

                // For local models (Apple Intelligence) and LM Studio, attempt to extract
                // visible on-screen text before sending the query. This gives text-only
                // models (Apple Intelligence) screen context they'd otherwise have none of,
                // and helps LM Studio models with weak vision by providing a text fallback
                // alongside the screenshot.
                var extractedScreenText: String? = nil
                if isOCRExtractionEnabled && (isLocalModel || isLMStudioModel) {
                    // Try OCR extraction with one retry. The Vision/Accessibility
                    // frameworks can fail with "fopen failed for data file" right
                    // after app launch before their caches are warm.
                    for ocrAttempt in 1...2 {
                        if let extractionResult = try? await TextExtractor().extract() {
                            let trimmedText = extractionResult.fullText.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmedText.isEmpty {
                                extractedScreenText = trimmedText
                                print("📄 OCR extracted \(trimmedText.count) chars via \(extractionResult.source)")
                                print("📄 OCR text:\n\(trimmedText)")
                                break
                            }
                        }
                        if ocrAttempt == 1 {
                            print("📄 OCR extraction failed, retrying after brief delay...")
                            try await Task.sleep(nanoseconds: 300_000_000) // 300ms
                        }
                    }
                }

                // Build the user prompt with screen text prepended when available.
                // The format gives the model clear context about what text is on screen
                // before the user's actual spoken question.
                let userPromptWithScreenContext: String = {
                    if let screenText = extractedScreenText {
                        return "Here is the text visible on the user's screen:\n\n\(screenText)\n\nUser's question: \(transcript)"
                    }
                    return transcript
                }()

                let voiceResponseStartTime = Date()

                if isLocalModel {
                    // Local mode (Apple Intelligence): text-only, no screenshots, no pointing.
                    // The on-device model has no vision capability, so we rely on OCR-extracted
                    // screen text (when available) to give it context about the user's screen.
                    let historyForAPI = conversationHistory.map { entry in
                        (userPlaceholder: entry.userTranscript, assistantResponse: entry.assistantResponse)
                    }

                    // Update the system prompt to reflect whether screen text is available.
                    // When OCR succeeded, tell the model it has that context; when it didn't,
                    // keep the original "no screen access" framing so the model doesn't hallucinate.
                    let localSystemPrompt: String
                    if extractedScreenText != nil {
                        localSystemPrompt = """
                        you are clicky, a helpful voice assistant that lives in the user's menu bar on macOS. \
                        you speak in a casual, friendly tone — short sentences, like talking to a friend. \
                        you CAN see the user's screen. the text content of their screen has been extracted and \
                        included below the user's question — this IS what's on their screen right now. treat it \
                        as your vision. when the user asks about what's on screen, answer based on that text. \
                        keep responses concise since they'll be spoken aloud. \
                        CRITICAL: you MUST reply in the SAME language the user uses. if the user writes in French, \
                        reply entirely in French. if in Spanish, reply in Spanish. match their language exactly.
                        """
                    } else {
                        localSystemPrompt = """
                        you are clicky, a helpful voice assistant that lives in the user's menu bar on macOS. \
                        you speak in a casual, friendly tone — short sentences, like talking to a friend. \
                        you don't have access to the user's screen in this mode, so just answer based on what they say. \
                        keep responses concise since they'll be spoken aloud. \
                        CRITICAL: you MUST reply in the SAME language the user uses. if the user writes in French, \
                        reply entirely in French. if in Spanish, reply in Spanish. match their language exactly.
                        """
                    }

                    let (responseText, _) = try await apfelAPI.chat(
                        systemPrompt: localSystemPrompt,
                        conversationHistory: historyForAPI,
                        userPrompt: userPromptWithScreenContext
                    )
                    fullResponseText = responseText + " [POINT:none]"
                } else if isLMStudioModel {
                    // LM Studio mode: local vision model via OpenAI-compatible API.
                    // Sends screenshots for visual context AND prepends OCR-extracted text
                    // so weak vision models can still read the screen reliably.
                    // Smaller screenshots (768px) for faster local inference.
                    screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG(maxDimension: 768)

                    guard !Task.isCancelled else { return }

                    let labeledImages = screenCaptures.map { capture in
                        let dimensionInfo = " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
                        return (data: capture.imageData, label: capture.label + dimensionInfo)
                    }

                    let historyForAPI = conversationHistory.map { entry in
                        (userPlaceholder: entry.userTranscript, assistantResponse: entry.assistantResponse)
                    }

                    let lmStudioStartTime = Date()
                    let (responseText, _) = try await lmStudioAPI.analyzeImageStreaming(
                        images: labeledImages,
                        systemPrompt: companionVoiceResponseSystemPrompt,
                        conversationHistory: historyForAPI,
                        userPrompt: userPromptWithScreenContext,
                        onTextChunk: { [weak self] accumulatedText in
                            guard let self, self.isVoiceStreamingTextEnabled else { return }
                            self.responseOverlayManager.updateStreamingText(accumulatedText)
                        }
                    )
                    let lmStudioElapsed = Date().timeIntervalSince(lmStudioStartTime)
                    print("⏱️ LM Studio response: \(String(format: "%.1f", lmStudioElapsed))s")
                    print("💬 LM Studio text: \(responseText)")
                    fullResponseText = responseText
                } else {
                    // Cloud mode (Claude): full vision pipeline with screenshots and pointing
                    screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()

                    guard !Task.isCancelled else { return }

                    // Build image labels with the actual screenshot pixel dimensions
                    // so Claude's coordinate space matches the image it sees. We
                    // scale from screenshot pixels to display points ourselves.
                    let labeledImages = screenCaptures.map { capture in
                        let dimensionInfo = " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
                        return (data: capture.imageData, label: capture.label + dimensionInfo)
                    }

                    // Pass conversation history so Claude remembers prior exchanges
                    let historyForAPI = conversationHistory.map { entry in
                        (userPlaceholder: entry.userTranscript, assistantResponse: entry.assistantResponse)
                    }

                    let (responseText, _) = try await claudeAPI.analyzeImageStreaming(
                        images: labeledImages,
                        systemPrompt: companionVoiceResponseSystemPrompt,
                        conversationHistory: historyForAPI,
                        userPrompt: transcript,
                        onTextChunk: { [weak self] accumulatedText in
                            guard let self, self.isVoiceStreamingTextEnabled else { return }
                            self.responseOverlayManager.updateStreamingText(accumulatedText)
                        }
                    )
                    fullResponseText = responseText
                }

                guard !Task.isCancelled else { return }

                // Strip NOTE tags first (multi-line content), then run all remaining
                // action tags through ActionTagParser in one pass, then parse POINT
                // from the fully-cleaned text so coordinates aren't mis-parsed.
                let voiceNoteResult = Self.parseAndStripNoteTags(from: fullResponseText)
                for note in voiceNoteResult.notes {
                    createAppleNote(title: note.title, content: note.content)
                }

                let voiceActionResult = ActionTagParser.parse(from: voiceNoteResult.textWithNotesStripped)
                // Pass screen captures so [CLICK:] tags can be mapped to screen coordinates
                executeActionTags(voiceActionResult, noteTitle: voiceNoteResult.notes.first?.title, screenCaptures: screenCaptures)

                // Parse the [POINT:...] tag from the fully action-stripped response
                let parseResult = Self.parsePointingCoordinates(from: voiceActionResult.cleanedText)
                let spokenText = parseResult.spokenText

                // Handle element pointing if Claude returned coordinates.
                // Switch to idle BEFORE setting the location so the triangle
                // becomes visible and can fly to the target. Without this, the
                // spinner hides the triangle and the flight animation is invisible.
                let hasPointCoordinate = parseResult.coordinate != nil
                if hasPointCoordinate {
                    voiceState = .idle
                }

                // Pick the screen capture matching Claude's screen number,
                // falling back to the cursor screen if not specified.
                // In local mode screenCaptures is empty so this returns nil.
                let targetScreenCapture: CompanionScreenCapture? = {
                    if let screenNumber = parseResult.screenNumber,
                       screenNumber >= 1 && screenNumber <= screenCaptures.count {
                        return screenCaptures[screenNumber - 1]
                    }
                    return screenCaptures.first(where: { $0.isCursorScreen })
                }()

                if let pointCoordinate = parseResult.coordinate,
                   let targetScreenCapture {
                    // Claude's coordinates are in the screenshot's pixel space
                    // (top-left origin, e.g. 1280x831). Scale to the display's
                    // point space (e.g. 1512x982), then convert to AppKit global coords.
                    let screenshotWidth = CGFloat(targetScreenCapture.screenshotWidthInPixels)
                    let screenshotHeight = CGFloat(targetScreenCapture.screenshotHeightInPixels)
                    let displayWidth = CGFloat(targetScreenCapture.displayWidthInPoints)
                    let displayHeight = CGFloat(targetScreenCapture.displayHeightInPoints)
                    let displayFrame = targetScreenCapture.displayFrame

                    // Clamp to screenshot coordinate space
                    let clampedX = max(0, min(pointCoordinate.x, screenshotWidth))
                    let clampedY = max(0, min(pointCoordinate.y, screenshotHeight))

                    // Scale from screenshot pixels to display points
                    let displayLocalX = clampedX * (displayWidth / screenshotWidth)
                    let displayLocalY = clampedY * (displayHeight / screenshotHeight)

                    // Convert from top-left origin (screenshot) to bottom-left origin (AppKit)
                    let appKitY = displayHeight - displayLocalY

                    // Convert display-local coords to global screen coords
                    let globalLocation = CGPoint(
                        x: displayLocalX + displayFrame.origin.x,
                        y: appKitY + displayFrame.origin.y
                    )

                    detectedElementScreenLocation = globalLocation
                    detectedElementDisplayFrame = displayFrame
                    ClickyAnalytics.trackElementPointed(elementLabel: parseResult.elementLabel)
                    print("🎯 Element pointing: (\(Int(pointCoordinate.x)), \(Int(pointCoordinate.y))) → \"\(parseResult.elementLabel ?? "element")\"")
                } else {
                    print("🎯 Element pointing: \(parseResult.elementLabel ?? "no element")")
                }

                // Save this exchange to conversation history (with the point tag
                // stripped so it doesn't confuse future context)
                conversationHistory.append((
                    userTranscript: transcript,
                    assistantResponse: spokenText
                ))

                // Keep only the last 10 exchanges to avoid unbounded context growth
                if conversationHistory.count > 10 {
                    conversationHistory.removeFirst(conversationHistory.count - 10)
                }

                // Auto-title the conversation from the first voice transcript
                autoTitleActiveConversationIfNeeded(from: transcript)

                // Mirror the voice exchange into chatMessages immediately so the chat
                // window updates without waiting for screenshot compression to finish.
                // The user message gets a pre-assigned UUID so screenshot files can be
                // named after it even though they're saved asynchronously.
                // Capture which app the user was looking at when they spoke
                let frontmostApp = NSWorkspace.shared.frontmostApplication
                let foregroundAppBundleID = frontmostApp?.bundleIdentifier
                let foregroundAppName = frontmostApp?.localizedName

                let voiceUserMessageID = UUID()
                chatMessages.append(ChatMessage(
                    id: voiceUserMessageID,
                    role: .user,
                    content: transcript,
                    source: .voice,
                    ocrText: extractedScreenText,
                    foregroundAppBundleID: foregroundAppBundleID,
                    foregroundAppName: foregroundAppName
                ))
                let voiceResponseDuration = Date().timeIntervalSince(voiceResponseStartTime)
                chatMessages.append(ChatMessage(role: .assistant, content: spokenText, source: .voice, modelID: resolvedModelIDForMessages, responseDurationSeconds: voiceResponseDuration))

                // Capture the active conversation ID now so the background screenshot
                // save writes to the correct conversation even if the user switches
                // conversations while TTS is playing.
                let conversationIDForSave = activeConversationID

                // Compress and save screenshots in a background task so it doesn't
                // delay TTS playback. Once saved, update the message with file names
                // and persist the conversation to disk.
                let rawCaptureDataItems = screenCaptures.map { $0.imageData }
                Task.detached(priority: .utility) { [weak self] in
                    guard let self else { return }
                    let savedFileNames = self.conversationStore.saveCompressedScreenshots(
                        rawCaptureDataItems,
                        forMessageWithID: voiceUserMessageID
                    )
                    await MainActor.run {
                        if let messageIndex = self.chatMessages.firstIndex(where: { $0.id == voiceUserMessageID }) {
                            self.chatMessages[messageIndex].screenshotFileNames = savedFileNames
                        }
                        // Save to the conversation that was active when the voice
                        // pipeline started, not necessarily the current active one
                        if let saveID = conversationIDForSave {
                            if saveID == self.activeConversationID {
                                // Still on the same conversation — save chatMessages directly
                                self.conversationStore.saveMessages(self.chatMessages, for: saveID)
                                self.updateConversationMetadata(for: saveID)
                            } else {
                                // User switched away — load, patch, and save the original conversation
                                var originalMessages = self.conversationStore.loadMessages(for: saveID)
                                if let messageIndex = originalMessages.firstIndex(where: { $0.id == voiceUserMessageID }) {
                                    originalMessages[messageIndex].screenshotFileNames = savedFileNames
                                }
                                self.conversationStore.saveMessages(originalMessages, for: saveID)
                            }
                        }
                    }
                }

                print("🧠 Conversation history: \(conversationHistory.count) exchanges")

                ClickyAnalytics.trackAIResponseReceived(response: spokenText)

                // Transition the streaming text overlay: update it with the final
                // clean text (tags stripped), then tell it to start its fade-out
                // timer so it stays readable while TTS plays then disappears.
                if isVoiceStreamingTextEnabled {
                    responseOverlayManager.updateStreamingText(spokenText)
                    responseOverlayManager.finishStreaming()
                }

                // Play the response via TTS. Keep the spinner (processing state)
                // until the audio actually starts playing, then switch to responding.
                if !spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    do {
                        try await speakTextWithActiveTTSProvider(spokenText)
                        // speakText returns after player.play() — audio is now playing
                        voiceState = .responding
                    } catch {
                        ClickyAnalytics.trackTTSError(error: error.localizedDescription)
                        print("⚠️ TTS error (\(selectedTTSProvider)): \(error)")
                        speakCreditsErrorFallback()
                    }
                }
            } catch is CancellationError {
                // User spoke again — response was interrupted, hide overlay immediately
                responseOverlayManager.hideOverlay()
            } catch {
                ClickyAnalytics.trackResponseError(error: error.localizedDescription)
                print("⚠️ Companion response error: \(error)")
                responseOverlayManager.hideOverlay()
                speakCreditsErrorFallback()
            }

            if !Task.isCancelled {
                voiceState = .idle
                scheduleTransientHideIfNeeded()
            }
        }
    }

    /// If the cursor is in transient mode (user toggled "Show Clicky" off),
    /// waits for TTS playback and any pointing animation to finish, then
    /// fades out the overlay after a 1-second pause. Cancelled automatically
    /// if the user starts another push-to-talk interaction.
    private func scheduleTransientHideIfNeeded() {
        guard !isClickyCursorEnabled && isOverlayVisible else { return }

        transientHideTask?.cancel()
        transientHideTask = Task {
            // Wait for TTS audio to finish playing
            while isActiveTTSPlaying {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Wait for pointing animation to finish (location is cleared
            // when the buddy flies back to the cursor)
            while detectedElementScreenLocation != nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Pause 1s after everything finishes, then fade out
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            overlayWindowManager.fadeOutAndHideOverlay()
            isOverlayVisible = false
        }
    }

    // MARK: - TTS Provider Helpers

    /// Routes a speak call to whichever TTS backend is currently selected.
    private func speakTextWithActiveTTSProvider(_ text: String) async throws {
        if selectedTTSProvider == "supertonic" {
            try await supertonicTTSClient.speakText(text)
        } else {
            try await elevenLabsTTSClient.speakText(text)
        }
    }

    /// Stops playback on whichever TTS backend is currently active.
    private func stopActiveTTSPlayback() {
        if selectedTTSProvider == "supertonic" {
            supertonicTTSClient.stopPlayback()
        } else {
            elevenLabsTTSClient.stopPlayback()
        }
    }

    /// True if the currently selected TTS backend has audio playing.
    private var isActiveTTSPlaying: Bool {
        if selectedTTSProvider == "supertonic" {
            return supertonicTTSClient.isPlaying
        } else {
            return elevenLabsTTSClient.isPlaying
        }
    }

    // MARK: - Test Helpers

    /// Tests the Anthropic API key by sending a minimal request to Claude.
    @Published private(set) var apiKeyTestStatus: String = ""

    func testAnthropicAPIKey() {
        guard isUsingDirectAPIKey else {
            apiKeyTestStatus = "No API key set"
            return
        }
        apiKeyTestStatus = "Testing..."
        Task {
            do {
                let (responseText, _) = try await claudeAPI.analyzeImageStreaming(
                    images: [],
                    systemPrompt: "Respond with exactly: OK",
                    conversationHistory: [],
                    userPrompt: "ping",
                    onTextChunk: { _ in }
                )
                if !responseText.isEmpty {
                    apiKeyTestStatus = "✅ API key working"
                } else {
                    apiKeyTestStatus = "⚠️ Empty response"
                }
            } catch {
                apiKeyTestStatus = "❌ \(error.localizedDescription)"
                print("🔑 API key test error: \(error)")
            }
        }
    }

    /// Speaks a sample phrase using the currently selected TTS provider.
    /// Used by the panel's test button to verify TTS without push-to-talk.
    @Published private(set) var ttsTestStatus: String = ""

    func testCurrentTTSProvider() {
        ttsTestStatus = "Testing \(selectedTTSProvider)..."
        Task {
            do {
                try await speakTextWithActiveTTSProvider("Hello! This is a test of the \(selectedTTSProvider) text to speech engine.")
                ttsTestStatus = "✅ \(selectedTTSProvider) working"
            } catch {
                ttsTestStatus = "❌ \(error.localizedDescription)"
                print("🔊 TTS test error: \(error)")
            }
        }
    }

    /// Records 3 seconds of mic audio and transcribes with the current STT provider.
    @Published private(set) var sttTestStatus: String = ""

    func testCurrentSTTProvider() {
        sttTestStatus = "🎙️ Recording 3s..."
        Task {
            do {
                let transcribedText = try await runShortSTTTest()
                if transcribedText.isEmpty {
                    sttTestStatus = "⚠️ No speech detected"
                } else {
                    sttTestStatus = "✅ \"\(transcribedText)\""
                }
            } catch {
                sttTestStatus = "❌ \(error.localizedDescription)"
                print("🎙️ STT test error: \(error)")
            }
        }
    }

    /// Records ~3 seconds of mic audio and runs it through the active STT provider.
    private func runShortSTTTest() async throws -> String {
        let audioEngine = AVAudioEngine()
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        var capturedBuffers: [AVAudioPCMBuffer] = []

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: recordingFormat) { buffer, _ in
            capturedBuffers.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()

        sttTestStatus = "🎙️ Speak now (3s)..."
        try await Task.sleep(nanoseconds: 3_000_000_000)

        audioEngine.stop()
        inputNode.removeTap(onBus: 0)

        sttTestStatus = "⏳ Transcribing..."

        var finalText = ""
        let providerPreference: BuddyTranscriptionProviderFactory.PreferredProvider =
            selectedSTTProvider == "parakeet" ? .parakeet : .assemblyAI
        let testProvider = BuddyTranscriptionProviderFactory.makeProvider(for: providerPreference)

        let session = try await testProvider.startStreamingSession(
            keyterms: [],
            onTranscriptUpdate: { text in
                finalText = text
            },
            onFinalTranscriptReady: { text in
                finalText = text
            },
            onError: { error in
                print("🎙️ STT test session error: \(error)")
            }
        )

        for buffer in capturedBuffers {
            session.appendAudioBuffer(buffer)
        }

        session.requestFinalTranscript()

        // Wait for finalization (up to 10s for model download on first use)
        for _ in 0..<100 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !finalText.isEmpty { break }
        }

        return finalText
    }

    /// Speaks a hardcoded error message using macOS system TTS when API
    /// credits run out. Uses NSSpeechSynthesizer so it works even when
    /// ElevenLabs is down.
    private func speakCreditsErrorFallback() {
        let utterance = "I'm all out of credits. Please DM Farza and tell him to bring me back to life."
        let synthesizer = NSSpeechSynthesizer()
        synthesizer.startSpeaking(utterance)
        voiceState = .responding
    }

    // MARK: - Note Tag Parsing + Apple Notes Creation

    /// Result of stripping [NOTE:title]...[/NOTE] blocks from a Claude response.
    struct NoteActionResult {
        /// The response text with all NOTE blocks removed and trimmed.
        let textWithNotesStripped: String
        /// Each note extracted from the response, in the order they appeared.
        let notes: [(title: String, content: String)]
    }

    /// Finds all [NOTE:title]content[/NOTE] blocks in Claude's response,
    /// extracts their title and content, and returns the response with those
    /// blocks fully removed. Safe to call with responses that contain zero blocks.
    static func parseAndStripNoteTags(from responseText: String) -> NoteActionResult {
        let notePattern = #"\[NOTE:([^\]]+)\]([\s\S]*?)\[/NOTE\]"#
        guard let noteRegex = try? NSRegularExpression(pattern: notePattern, options: []) else {
            return NoteActionResult(textWithNotesStripped: responseText, notes: [])
        }

        let nsRange = NSRange(responseText.startIndex..., in: responseText)
        let matches = noteRegex.matches(in: responseText, range: nsRange)

        var extractedNotes: [(title: String, content: String)] = []
        for match in matches {
            guard let titleRange = Range(match.range(at: 1), in: responseText),
                  let contentRange = Range(match.range(at: 2), in: responseText) else { continue }
            let title = String(responseText[titleRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            let content = String(responseText[contentRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            extractedNotes.append((title: title, content: content))
        }

        // Replace all NOTE blocks with empty string in one pass
        let strippedText = noteRegex
            .stringByReplacingMatches(in: responseText, range: nsRange, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return NoteActionResult(textWithNotesStripped: strippedText, notes: extractedNotes)
    }

    /// Creates a new note in Apple Notes via AppleScript.
    /// Runs on a background thread so it never blocks the UI or TTS playback.
    /// The title stays on one line; newlines in the content become AppleScript
    /// `& return &` concatenations since AppleScript strings can't span lines.
    func createAppleNote(title: String, content: String) {
        // Escape backslashes and double-quotes for embedding in AppleScript string literals.
        let escapedTitle = title
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ") // titles are single-line

        let escapedContent = content
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            // AppleScript string literals can't contain literal newlines —
            // break them into concatenated strings joined by `return`.
            .replacingOccurrences(of: "\n", with: "\" & return & \"")

        let appleScriptSource = """
        tell application "Notes"
            make new note at folder "Notes" with properties {name:"\(escapedTitle)", body:"\(escapedContent)"}
        end tell
        """

        // NSAppleScript.executeAndReturnError is synchronous and can take up to
        // a second while Notes processes the request. Dispatch to a background
        // queue to keep the main actor (and TTS playback) unblocked.
        DispatchQueue.global(qos: .utility).async {
            var errorInfo: NSDictionary?
            guard let script = NSAppleScript(source: appleScriptSource) else {
                print("⚠️ Apple Notes: failed to create NSAppleScript for note \"\(title)\"")
                return
            }
            script.executeAndReturnError(&errorInfo)
            if let errorInfo {
                print("⚠️ Apple Notes creation failed for \"\(title)\": \(errorInfo)")
            } else {
                print("📝 Apple Note created: \"\(title)\"")
            }
        }
    }

    // MARK: - Action Tag Execution

    /// Executes all actions extracted by ActionTagParser: learning log entries,
    /// open targets, shortcut runs, reminders, music control, and screen clicks.
    /// `noteTitle` is the title of any Apple Note created in the same response
    /// (used to link LOG entries). `screenCaptures` is passed in from the voice
    /// pipeline so [CLICK:] tags can be mapped from screenshot pixels to screen
    /// coordinates — pass an empty array from the chat pipeline (no screenshots).
    /// All actions run on the main actor or background queues and never block TTS.
    func executeActionTags(
        _ actions: ParsedActionTags,
        noteTitle: String?,
        screenCaptures: [CompanionScreenCapture] = []
    ) {
        // Learning log entries — only written when the toggle is on
        if isLearningLogEnabled {
            for logEntry in actions.logEntries {
                let entry = LearningEntry(
                    app: logEntry.app,
                    topic: logEntry.topic,
                    noteTitle: noteTitle
                )
                learningLogStore.append(entry)
            }
        }

        // Open URLs or apps via NSWorkspace — only when the toggle is on
        if isOpenActionEnabled {
            for target in actions.openTargets {
                ActionExecutor.openURLOrApp(target)
            }
        }

        // Apple Shortcuts — run by name via the `shortcuts` CLI, only when the toggle is on
        if isShortcutActionEnabled {
            for shortcutName in actions.shortcutNames {
                ActionExecutor.runShortcut(named: shortcutName)
            }
        }

        // Reminders via EventKit — async, runs in background, only when the toggle is on
        if isRemindActionEnabled {
            for reminder in actions.reminders {
                Task {
                    await ActionExecutor.createReminder(text: reminder.text, dateHint: reminder.dateHint)
                }
            }
        }

        // Music control via media key simulation — only when the toggle is on
        if isMusicActionEnabled {
            for musicAction in actions.musicActions {
                MusicController.handleMusicAction(musicAction)
            }
        }

        // Left-click simulation — only when the toggle is on and screen captures are available
        // (screen captures are only present in the voice pipeline, not the chat pipeline)
        if isClickActionEnabled, !screenCaptures.isEmpty {
            for clickTarget in actions.clickTargets {
                simulateClick(clickTarget: clickTarget, usingScreenCaptures: screenCaptures)
            }
        }
    }

    /// Maps a [CLICK:] tag's screenshot-pixel coordinate to a global AppKit screen
    /// coordinate and fires a CGEvent left-click at that position.
    ///
    /// The coordinate mapping is identical to the [POINT:] system: screenshot pixels
    /// scale to display points, then flip from top-left to bottom-left AppKit origin.
    /// This ensures the click lands on the correct pixel regardless of display scaling.
    private func simulateClick(clickTarget: ParsedClickTarget, usingScreenCaptures screenCaptures: [CompanionScreenCapture]) {
        // Pick the right screen — prefer the screen number Claude specified,
        // fall back to the screen where the cursor currently sits.
        let targetCapture: CompanionScreenCapture? = {
            if let screenNumber = clickTarget.screenNumber,
               screenNumber >= 1, screenNumber <= screenCaptures.count {
                return screenCaptures[screenNumber - 1]
            }
            return screenCaptures.first(where: { $0.isCursorScreen })
        }()

        guard let targetCapture else {
            print("⚠️ [CLICK] no matching screen capture for target '\(clickTarget.label ?? "unknown")'")
            return
        }

        let screenshotWidth  = CGFloat(targetCapture.screenshotWidthInPixels)
        let screenshotHeight = CGFloat(targetCapture.screenshotHeightInPixels)
        let displayWidth     = CGFloat(targetCapture.displayWidthInPoints)
        let displayHeight    = CGFloat(targetCapture.displayHeightInPoints)
        let displayFrame     = targetCapture.displayFrame

        // Clamp to valid screenshot bounds before scaling
        let clampedX = max(0, min(clickTarget.pixelCoordinate.x, screenshotWidth))
        let clampedY = max(0, min(clickTarget.pixelCoordinate.y, screenshotHeight))

        // Scale from screenshot pixels → display points
        let displayLocalX = clampedX * (displayWidth / screenshotWidth)
        let displayLocalY = clampedY * (displayHeight / screenshotHeight)

        // Convert from top-left origin (screenshot) → bottom-left origin (AppKit)
        let appKitY = displayHeight - displayLocalY

        // Convert display-local → global AppKit coordinates
        let globalAppKitPoint = CGPoint(
            x: displayLocalX + displayFrame.origin.x,
            y: appKitY + displayFrame.origin.y
        )

        // CoreGraphics uses top-left origin for the full virtual screen space.
        // The total virtual height is the union of all screen frames' maxY.
        let totalVirtualScreenHeight = NSScreen.screens.map { $0.frame.maxY }.max() ?? displayHeight
        let cgClickPoint = CGPoint(
            x: globalAppKitPoint.x,
            y: totalVirtualScreenHeight - globalAppKitPoint.y
        )

        // Fire the left click via CGEvent — the OS delivers it to whichever
        // window is at that screen coordinate, just like a real mouse click.
        guard let mouseDown = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                                      mouseCursorPosition: cgClickPoint, mouseButton: .left),
              let mouseUp   = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                                      mouseCursorPosition: cgClickPoint, mouseButton: .left) else {
            print("⚠️ [CLICK] failed to create CGEvent for '\(clickTarget.label ?? "unknown")'")
            return
        }

        mouseDown.post(tap: .cgHidEventTap)
        mouseUp.post(tap: .cgHidEventTap)

        // Move the cursor overlay to the click target for visual confirmation,
        // exactly like [POINT:] does. This shows the user where Clicky clicked.
        detectedElementScreenLocation = globalAppKitPoint
        detectedElementDisplayFrame   = displayFrame
        detectedElementBubbleText     = clickTarget.label.map { "clicking \($0)" }

        print("🖱️ [CLICK] '\(clickTarget.label ?? "element")' at screenshot (\(Int(clickTarget.pixelCoordinate.x)), \(Int(clickTarget.pixelCoordinate.y))) → screen (\(Int(cgClickPoint.x)), \(Int(cgClickPoint.y)))")
    }

    // MARK: - Point Tag Parsing

    /// Result of parsing a [POINT:...] tag from Claude's response.
    struct PointingParseResult {
        /// The response text with the [POINT:...] tag removed — this is what gets spoken.
        let spokenText: String
        /// The parsed pixel coordinate, or nil if Claude said "none" or no tag was found.
        let coordinate: CGPoint?
        /// Short label describing the element (e.g. "run button"), or "none".
        let elementLabel: String?
        /// Which screen the coordinate refers to (1-based), or nil to default to cursor screen.
        let screenNumber: Int?
    }

    /// Parses a [POINT:x,y:label:screenN] or [POINT:none] tag from the end of Claude's response.
    /// Returns the spoken text (tag removed) and the optional coordinate + label + screen number.
    static func parsePointingCoordinates(from responseText: String) -> PointingParseResult {
        // Match [POINT:none] or [POINT:123,456:label] or [POINT:123,456:label:screen2]
        let pattern = #"\[POINT:(?:none|(\d+)\s*,\s*(\d+)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?)\]\s*$"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: responseText, range: NSRange(responseText.startIndex..., in: responseText)) else {
            // No tag found at all
            return PointingParseResult(spokenText: responseText, coordinate: nil, elementLabel: nil, screenNumber: nil)
        }

        // Remove the tag from the spoken text
        let tagRange = Range(match.range, in: responseText)!
        let spokenText = String(responseText[..<tagRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)

        // Check if it's [POINT:none]
        guard match.numberOfRanges >= 3,
              let xRange = Range(match.range(at: 1), in: responseText),
              let yRange = Range(match.range(at: 2), in: responseText),
              let x = Double(responseText[xRange]),
              let y = Double(responseText[yRange]) else {
            return PointingParseResult(spokenText: spokenText, coordinate: nil, elementLabel: "none", screenNumber: nil)
        }

        var elementLabel: String? = nil
        if match.numberOfRanges >= 4, let labelRange = Range(match.range(at: 3), in: responseText) {
            elementLabel = String(responseText[labelRange]).trimmingCharacters(in: .whitespaces)
        }

        var screenNumber: Int? = nil
        if match.numberOfRanges >= 5, let screenRange = Range(match.range(at: 4), in: responseText) {
            screenNumber = Int(responseText[screenRange])
        }

        return PointingParseResult(
            spokenText: spokenText,
            coordinate: CGPoint(x: x, y: y),
            elementLabel: elementLabel,
            screenNumber: screenNumber
        )
    }

    // MARK: - Onboarding Video

    /// Sets up the onboarding video player, starts playback, and schedules
    /// the demo interaction at 40s. Called by BlueCursorView when onboarding starts.
    func setupOnboardingVideo() {
        guard let videoURL = URL(string: "https://stream.mux.com/e5jB8UuSrtFABVnTHCR7k3sIsmcUHCyhtLu1tzqLlfs.m3u8") else { return }

        let player = AVPlayer(url: videoURL)
        player.isMuted = false
        player.volume = 0.0
        self.onboardingVideoPlayer = player
        self.showOnboardingVideo = true
        self.onboardingVideoOpacity = 0.0

        // Start playback immediately — the video plays while invisible,
        // then we fade in both the visual and audio over 1s.
        player.play()

        // Wait for SwiftUI to mount the view, then set opacity to 1.
        // The .animation modifier on the view handles the actual animation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.onboardingVideoOpacity = 1.0
            // Fade audio volume from 0 → 1 over 2s to match visual fade
            self.fadeInVideoAudio(player: player, targetVolume: 1.0, duration: 2.0)
        }

        // At 40 seconds into the video, trigger the onboarding demo where
        // Clicky flies to something interesting on screen and comments on it
        let demoTriggerTime = CMTime(seconds: 40, preferredTimescale: 600)
        onboardingDemoTimeObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: demoTriggerTime)],
            queue: .main
        ) { [weak self] in
            ClickyAnalytics.trackOnboardingDemoTriggered()
            self?.performOnboardingDemoInteraction()
        }

        // Fade out and clean up when the video finishes
        onboardingVideoEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            ClickyAnalytics.trackOnboardingVideoCompleted()
            self.onboardingVideoOpacity = 0.0
            // Wait for the 2s fade-out animation to complete before tearing down
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.tearDownOnboardingVideo()
                // After the video disappears, stream in the prompt to try talking
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.startOnboardingPromptStream()
                }
            }
        }
    }

    func tearDownOnboardingVideo() {
        showOnboardingVideo = false
        if let timeObserver = onboardingDemoTimeObserver {
            onboardingVideoPlayer?.removeTimeObserver(timeObserver)
            onboardingDemoTimeObserver = nil
        }
        onboardingVideoPlayer?.pause()
        onboardingVideoPlayer = nil
        if let observer = onboardingVideoEndObserver {
            NotificationCenter.default.removeObserver(observer)
            onboardingVideoEndObserver = nil
        }
    }

    private func startOnboardingPromptStream() {
        let message = "press control + option and introduce yourself"
        onboardingPromptText = ""
        showOnboardingPrompt = true
        onboardingPromptOpacity = 0.0

        withAnimation(.easeIn(duration: 0.4)) {
            onboardingPromptOpacity = 1.0
        }

        var currentIndex = 0
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { timer in
            guard currentIndex < message.count else {
                timer.invalidate()
                // Auto-dismiss after 10 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                    guard self.showOnboardingPrompt else { return }
                    withAnimation(.easeOut(duration: 0.3)) {
                        self.onboardingPromptOpacity = 0.0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        self.showOnboardingPrompt = false
                        self.onboardingPromptText = ""
                    }
                }
                return
            }
            let index = message.index(message.startIndex, offsetBy: currentIndex)
            self.onboardingPromptText.append(message[index])
            currentIndex += 1
        }
    }

    /// Gradually raises an AVPlayer's volume from its current level to the
    /// target over the specified duration, creating a smooth audio fade-in.
    private func fadeInVideoAudio(player: AVPlayer, targetVolume: Float, duration: Double) {
        let steps = 20
        let stepInterval = duration / Double(steps)
        let volumeIncrement = (targetVolume - player.volume) / Float(steps)
        var stepsRemaining = steps

        Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { timer in
            stepsRemaining -= 1
            player.volume += volumeIncrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.volume = targetVolume
            }
        }
    }

    // MARK: - Onboarding Demo Interaction

    private static let onboardingDemoSystemPrompt = """
    you're clicky, a small blue cursor buddy living on the user's screen. you're showing off during onboarding — look at their screen and find ONE specific, concrete thing to point at. pick something with a clear name or identity: a specific app icon (say its name), a specific word or phrase of text you can read, a specific filename, a specific button label, a specific tab title, a specific image you can describe. do NOT point at vague things like "a window" or "some text" — be specific about exactly what you see.

    make a short quirky 3-6 word observation about the specific thing you picked — something fun, playful, or curious that shows you actually read/recognized it. no emojis ever. NEVER quote or repeat text you see on screen — just react to it. keep it to 6 words max, no exceptions.

    CRITICAL COORDINATE RULE: you MUST only pick elements near the CENTER of the screen. your x coordinate must be between 20%-80% of the image width. your y coordinate must be between 20%-80% of the image height. do NOT pick anything in the top 20%, bottom 20%, left 20%, or right 20% of the screen. no menu bar items, no dock icons, no sidebar items, no items near any edge. only things clearly in the middle area of the screen. if the only interesting things are near the edges, pick something boring in the center instead.

    respond with ONLY your short comment followed by the coordinate tag. nothing else. all lowercase.

    format: your comment [POINT:x,y:label]

    the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. origin (0,0) is top-left. x increases rightward, y increases downward.
    """

    /// Captures a screenshot and asks Claude to find something interesting to
    /// point at, then triggers the buddy's flight animation. Used during
    /// onboarding to demo the pointing feature while the intro video plays.
    func performOnboardingDemoInteraction() {
        // Don't interrupt an active voice response
        guard voiceState == .idle || voiceState == .responding else { return }

        Task {
            do {
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()

                // Only send the cursor screen so Claude can't pick something
                // on a different monitor that we can't point at.
                guard let cursorScreenCapture = screenCaptures.first(where: { $0.isCursorScreen }) else {
                    print("🎯 Onboarding demo: no cursor screen found")
                    return
                }

                let dimensionInfo = " (image dimensions: \(cursorScreenCapture.screenshotWidthInPixels)x\(cursorScreenCapture.screenshotHeightInPixels) pixels)"
                let labeledImages = [(data: cursorScreenCapture.imageData, label: cursorScreenCapture.label + dimensionInfo)]

                let (fullResponseText, _) = try await claudeAPI.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: Self.onboardingDemoSystemPrompt,
                    userPrompt: "look around my screen and find something interesting to point at",
                    onTextChunk: { _ in }
                )

                let parseResult = Self.parsePointingCoordinates(from: fullResponseText)

                guard let pointCoordinate = parseResult.coordinate else {
                    print("🎯 Onboarding demo: no element to point at")
                    return
                }

                let screenshotWidth = CGFloat(cursorScreenCapture.screenshotWidthInPixels)
                let screenshotHeight = CGFloat(cursorScreenCapture.screenshotHeightInPixels)
                let displayWidth = CGFloat(cursorScreenCapture.displayWidthInPoints)
                let displayHeight = CGFloat(cursorScreenCapture.displayHeightInPoints)
                let displayFrame = cursorScreenCapture.displayFrame

                let clampedX = max(0, min(pointCoordinate.x, screenshotWidth))
                let clampedY = max(0, min(pointCoordinate.y, screenshotHeight))
                let displayLocalX = clampedX * (displayWidth / screenshotWidth)
                let displayLocalY = clampedY * (displayHeight / screenshotHeight)
                let appKitY = displayHeight - displayLocalY
                let globalLocation = CGPoint(
                    x: displayLocalX + displayFrame.origin.x,
                    y: appKitY + displayFrame.origin.y
                )

                // Set custom bubble text so the pointing animation uses Claude's
                // comment instead of a random phrase
                detectedElementBubbleText = parseResult.spokenText
                detectedElementScreenLocation = globalLocation
                detectedElementDisplayFrame = displayFrame
                print("🎯 Onboarding demo: pointing at \"\(parseResult.elementLabel ?? "element")\" — \"\(parseResult.spokenText)\"")
            } catch {
                print("⚠️ Onboarding demo error: \(error)")
            }
        }
    }
}
