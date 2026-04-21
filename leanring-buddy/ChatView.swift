//
//  ChatView.swift
//  leanring-buddy
//
//  SwiftUI chat window UI. Shows the full conversation history (voice + text
//  exchanges), lets the user type new messages, and streams Claude's response
//  in-place as tokens arrive. Both voice and text messages appear here so the
//  user has a single place to review what was said and what Clicky answered.
//

import AppKit
import SwiftUI

// MARK: - Root View

struct ChatView: View {
    @ObservedObject var companionManager: CompanionManager
    @State private var inputText = ""

    var body: some View {
        VStack(spacing: 0) {
            if companionManager.chatMessages.isEmpty {
                emptyStateView
            } else {
                messageListView
            }
            dividerLine
            inputBarView
        }
        .background(DS.Colors.background)
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 32, weight: .light))
                .foregroundColor(DS.Colors.textTertiary)
            Text("Ask Clicky anything")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
            Text("Type below, or use push-to-talk (ctrl+option)")
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textTertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(DS.Colors.background)
    }

    // MARK: - Message List

    private var messageListView: some View {
        ScrollViewReader { scrollProxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 12) {
                    ForEach(companionManager.chatMessages) { message in
                        ChatMessageBubbleView(
                            message: message,
                            conversationStore: companionManager.conversationStore,
                            companionManager: companionManager
                        )
                    }

                    // Typing indicator appears below the last message while Clicky
                    // is generating a response and the placeholder content is still empty
                    if companionManager.isSendingChatMessage,
                       companionManager.chatMessages.last?.role == .assistant,
                       companionManager.chatMessages.last?.content.isEmpty == true {
                        TypingIndicatorView()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                    }
                }
                .padding(.vertical, 14)

                // Invisible bottom anchor for programmatic scrolling
                Color.clear
                    .frame(height: 1)
                    .id("chatBottomAnchor")
            }
            .background(DS.Colors.background)
            .onAppear {
                scrollProxy.scrollTo("chatBottomAnchor", anchor: .bottom)
            }
            // Scroll to bottom when a new message is appended
            .onChange(of: companionManager.chatMessages.count) { _ in
                withAnimation(.easeOut(duration: 0.15)) {
                    scrollProxy.scrollTo("chatBottomAnchor", anchor: .bottom)
                }
            }
            // Scroll to bottom as streaming content grows (keeps latest text in view)
            .onChange(of: companionManager.chatMessages.last?.content) { _ in
                scrollProxy.scrollTo("chatBottomAnchor", anchor: .bottom)
            }
        }
    }

    // MARK: - Input Bar

    private var inputBarView: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Message Clicky...", text: $inputText, axis: .vertical)
                .lineLimit(1...6)
                .font(.system(size: 13))
                .foregroundColor(DS.Colors.textPrimary)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(DS.Colors.surface2)
                .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.medium))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 1)
                )
                .onSubmit { sendMessageIfNonEmpty() }

            SendButtonView(
                isEnabled: !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && !companionManager.isSendingChatMessage,
                onSend: sendMessageIfNonEmpty
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(DS.Colors.surface1)
    }

    // MARK: - Helpers

    private var dividerLine: some View {
        Rectangle()
            .fill(DS.Colors.borderSubtle)
            .frame(height: 1)
    }

    private func sendMessageIfNonEmpty() {
        let trimmedText = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty, !companionManager.isSendingChatMessage else { return }
        inputText = ""
        companionManager.sendChatTextMessage(trimmedText)
    }
}

// MARK: - Send Button

/// Icon button that sends the user's message. Disabled while Clicky is generating a response.
private struct SendButtonView: View {
    let isEnabled: Bool
    let onSend: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSend) {
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 28))
                .foregroundColor(buttonColor)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { hovering in
            isHovered = hovering
            if hovering && isEnabled {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }

    private var buttonColor: Color {
        if !isEnabled {
            return DS.Colors.textTertiary
        }
        return isHovered ? DS.Colors.blue500 : DS.Colors.blue600
    }
}

// MARK: - Message Bubble

/// Renders a single chat message. User messages are right-aligned with a blue bubble;
/// assistant messages are left-aligned with a dark surface bubble. Voice messages get
/// a mic badge so the user can tell which exchanges came from push-to-talk.
/// Voice user messages also show a horizontal strip of screenshot thumbnails so the
/// user can see exactly what Clicky was looking at when it answered.
private struct ChatMessageBubbleView: View {
    let message: ChatMessage
    let conversationStore: ConversationStore
    let companionManager: CompanionManager
    @State private var selectedScreenshotFileURL: URL? = nil

    var body: some View {
        if message.source == .readAloud {
            ReadAloudMessageCardView(
                message: message,
                conversationStore: conversationStore,
                companionManager: companionManager
            )
            .padding(.horizontal, 16)
        } else {
            HStack(alignment: .bottom, spacing: 6) {
                if message.role == .user {
                    Spacer(minLength: 60)
                    userBubble
                } else {
                    assistantBubble
                    Spacer(minLength: 60)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: User bubble

    private var userBubble: some View {
        VStack(alignment: .trailing, spacing: 6) {
            // Screenshot thumbnails — only for voice messages that have saved captures
            if !message.screenshotFileNames.isEmpty {
                screenshotThumbnailStrip
            }

            Text(message.content)
                .font(.system(size: 13))
                .foregroundColor(.white)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(DS.Colors.helpChatUserBubble)
                .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.large))

            bottomMetaRow(role: .user)
        }
    }

    // MARK: Screenshot thumbnails

    /// A horizontal scrollable strip of screenshot previews shown above the user's
    /// voice message text bubble. Each thumbnail is up to 160 px tall with rounded
    /// corners. Scrollable so multi-monitor captures don't overflow the bubble.
    private var screenshotThumbnailStrip: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 8) {
                ForEach(message.screenshotFileNames, id: \.self) { fileName in
                    let screenshotFileURL = conversationStore.screenshotFileURL(fileName: fileName)
                    ScreenshotThumbnailView(
                        fileURL: screenshotFileURL,
                        onTapThumbnail: {
                            selectedScreenshotFileURL = screenshotFileURL
                        }
                    )
                }
            }

            // App icon + name caption below the thumbnails
            if let appName = message.foregroundAppName {
                screenshotAppCaption(appName: appName, bundleID: message.foregroundAppBundleID)
            }
        }
        .sheet(isPresented: isScreenshotDetailPresentedBinding) {
            if let selectedScreenshotFileURL {
                ScreenshotDetailView(fileURL: selectedScreenshotFileURL)
            }
        }
    }

    private var isScreenshotDetailPresentedBinding: Binding<Bool> {
        Binding(
            get: { selectedScreenshotFileURL != nil },
            set: { isPresented in
                if !isPresented {
                    selectedScreenshotFileURL = nil
                }
            }
        )
    }

    /// Small caption showing the frontmost app icon and name below screenshot thumbnails.
    private func screenshotAppCaption(appName: String, bundleID: String?) -> some View {
        HStack(spacing: 4) {
            if let bundleID,
               let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                    .resizable()
                    .scaledToFit()
                    .frame(width: 12, height: 12)
            }
            Text(appName)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
                .lineLimit(1)
        }
    }

    // MARK: Assistant bubble

    private var assistantBubble: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Show the accumulated (possibly still-streaming) response text.
            // An empty content string means the first token hasn't arrived yet;
            // the parent view shows a TypingIndicatorView in that case instead.
            if !message.content.isEmpty {
                assistantTextView
            }

            bottomMetaRow(role: .assistant)
        }
    }

    private var assistantTextView: some View {
        Group {
            // Render markdown so Claude's **bold**, `code`, and *italic* formatting
            // displays correctly. Falls back to plain text if the markdown string
            // is malformed (can happen mid-stream for incomplete syntax).
            if let attributed = try? AttributedString(markdown: message.content,
                                                      options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                Text(attributed)
                    .font(.system(size: 13))
                    .foregroundColor(DS.Colors.textPrimary)
                    .textSelection(.enabled)
            } else {
                Text(message.content)
                    .font(.system(size: 13))
                    .foregroundColor(DS.Colors.textPrimary)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(DS.Colors.surface2)
        .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.large))
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large)
                .stroke(DS.Colors.borderSubtle, lineWidth: 1)
        )
    }

    // MARK: Timestamp + source badge + model info

    private func bottomMetaRow(role: ChatMessageRole) -> some View {
        HStack(spacing: 4) {
            if role == .user && message.source == .voice {
                Image(systemName: "mic.fill")
                    .font(.system(size: 9))
                    .foregroundColor(DS.Colors.textTertiary)
            }

            // OCR badge for user messages that included screen text extraction
            if role == .user && message.ocrText != nil {
                Image(systemName: "text.viewfinder")
                    .font(.system(size: 9))
                    .foregroundColor(DS.Colors.textTertiary)
            }

            // Screenshot count for user messages with captures
            if role == .user && !message.screenshotFileNames.isEmpty {
                HStack(spacing: 2) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 8))
                    Text("\(message.screenshotFileNames.count)")
                        .font(.system(size: 9))
                }
                .foregroundColor(DS.Colors.textTertiary)
            }

            Text(formattedTimestamp)
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.textTertiary)

            if role == .assistant && message.source == .voice {
                Image(systemName: "mic.fill")
                    .font(.system(size: 9))
                    .foregroundColor(DS.Colors.textTertiary)
            }

            // Model badge for assistant messages
            if role == .assistant, let modelID = message.modelID {
                HStack(spacing: 3) {
                    modelBadgeIcon(modelID)
                    Text(shortModelName(modelID))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    Capsule()
                        .fill(Color.white.opacity(0.06))
                )
            }

            // Response duration for assistant messages
            if role == .assistant, let duration = message.responseDurationSeconds {
                Text(formattedDuration(duration))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary.opacity(0.7))
            }
        }
    }

    @ViewBuilder
    private func modelBadgeIcon(_ modelID: String) -> some View {
        let size: CGFloat = 10
        switch modelID {
        case "claude-opus-4-6", "claude-sonnet-4-6":
            Image("icon-anthropic").resizable().scaledToFit().frame(width: size, height: size)
        case "lmstudio":
            Image("icon-lmstudio").resizable().scaledToFit().frame(width: size, height: size)
        case "local":
            Image(systemName: "apple.logo").font(.system(size: 8))
                .foregroundColor(DS.Colors.textTertiary)
        default:
            if modelID.lowercased().contains("gemma") {
                Image("icon-gemma").resizable().scaledToFit().frame(width: size, height: size)
            } else if !modelID.starts(with: "claude-") {
                // Non-Claude models are likely from LM Studio
                Image("icon-lmstudio").resizable().scaledToFit().frame(width: size, height: size)
            }
        }
    }

    private func shortModelName(_ modelID: String) -> String {
        switch modelID {
        case "claude-opus-4-6":   return "Opus"
        case "claude-sonnet-4-6": return "Sonnet"
        case "local":             return "Local"
        case "lmstudio":         return "LM Studio"
        default:                  return modelID
        }
    }

    private func formattedDuration(_ seconds: Double) -> String {
        if seconds < 1 {
            return String(format: "%.0fms", seconds * 1000)
        } else if seconds < 10 {
            return String(format: "%.1fs", seconds)
        } else {
            return String(format: "%.0fs", seconds)
        }
    }

    private var formattedTimestamp: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: message.timestamp)
    }
}

// MARK: - Read-aloud Card

/// Dedicated card shown for every ⌃⇧L read-aloud capture. Lays out a
/// screenshot of what was read, the extracted text (collapsed by default),
/// and a Replay button that replays the captured WAV while the highlight
/// overlay re-animates over the live screen using the stored word timings.
private struct ReadAloudMessageCardView: View {
    let message: ChatMessage
    let conversationStore: ConversationStore
    let companionManager: CompanionManager

    @State private var isTextExpanded: Bool = false
    @State private var isHoveringPlay: Bool = false
    @State private var isHoveringViewPopover: Bool = false
    @State private var selectedScreenshotFileURL: URL? = nil

    private let collapsedTextLineLimit: Int = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerRow
            if !message.screenshotFileNames.isEmpty {
                screenshotStrip
            }
            extractedTextBlock
            footerRow
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large)
                .fill(DS.Colors.surface2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large)
                .stroke(DS.Colors.borderSubtle, lineWidth: 1)
        )
        .sheet(isPresented: isScreenshotDetailPresentedBinding) {
            if let selectedScreenshotFileURL {
                ScreenshotDetailView(fileURL: selectedScreenshotFileURL)
            }
        }
    }

    // MARK: Header

    private var headerRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)
            Text(headerTitleText)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)
            if let bundleID = message.foregroundAppBundleID,
               let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                    .resizable()
                    .scaledToFit()
                    .frame(width: 14, height: 14)
            }
            if let appName = message.foregroundAppName {
                Text(appName)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .lineLimit(1)
            }
            Spacer()
            Text(formattedTimestamp)
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.textTertiary)
        }
    }

    private var headerTitleText: String {
        message.foregroundAppName != nil ? "Read aloud from" : "Read aloud"
    }

    // MARK: Screenshots

    private var screenshotStrip: some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(message.screenshotFileNames, id: \.self) { fileName in
                let screenshotFileURL = conversationStore.screenshotFileURL(fileName: fileName)
                ScreenshotThumbnailView(
                    fileURL: screenshotFileURL,
                    onTapThumbnail: { selectedScreenshotFileURL = screenshotFileURL }
                )
            }
        }
    }

    private var isScreenshotDetailPresentedBinding: Binding<Bool> {
        Binding(
            get: { selectedScreenshotFileURL != nil },
            set: { if !$0 { selectedScreenshotFileURL = nil } }
        )
    }

    // MARK: Text block

    private var extractedTextBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(message.content)
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(isTextExpanded ? nil : collapsedTextLineLimit)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Only offer expand/collapse when the text actually wraps past the
            // collapsed line limit — short reads show their full content already.
            if message.content.count > 200 || message.content.contains("\n") {
                Button(action: { withAnimation { isTextExpanded.toggle() } }) {
                    Text(isTextExpanded ? "Show less" : "Show more")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.blue500)
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
            }
        }
    }

    // MARK: Footer (replay + metadata)

    private var footerRow: some View {
        HStack(spacing: 8) {
            playAudioButton
            if !message.screenshotFileNames.isEmpty {
                viewPopoverButton
            }
            if let capture = message.readAloudCapture {
                Text(formattedDurationText(capture.audioDurationSeconds))
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
                Text("· \(capture.wordTimings.count) words")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
            } else {
                Text("Capturing audio…")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            Spacer()
        }
    }

    /// Plays just the captured audio — no popover, no live highlight. For
    /// the common "just read it to me again" case, or when the message has
    /// no screenshot attached (capture preference was off).
    private var playAudioButton: some View {
        let isAudioOnlyPlayingThisMessage =
            companionManager.isAudioOnlyReplayPlayingMessageID == message.id

        return Button(action: {
            guard message.readAloudCapture != nil else { return }
            companionManager.toggleAudioOnlyReadAloudReplay(for: message)
        }) {
            HStack(spacing: 6) {
                Image(systemName: isAudioOnlyPlayingThisMessage ? "stop.fill" : "play.fill")
                    .font(.system(size: 10, weight: .bold))
                Text(isAudioOnlyPlayingThisMessage ? "Stop" : "Play")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(isAudioOnlyPlayingThisMessage ? Color.red : DS.Colors.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(
                    isAudioOnlyPlayingThisMessage
                        ? Color.red.opacity(0.22)
                        : (isHoveringPlay ? DS.Colors.blue500.opacity(0.3) : Color.white.opacity(0.06))
                )
            )
        }
        .buttonStyle(.plain)
        .disabled(message.readAloudCapture == nil)
        .opacity(message.readAloudCapture == nil ? 0.5 : 1.0)
        .onHover { hovering in
            isHoveringPlay = hovering
            if hovering && message.readAloudCapture != nil {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }

    /// Opens the full replay popover window: the captured screenshot with
    /// the highlight animating over each spoken word in sync with audio.
    /// Hidden when the message has no screenshot (capture was disabled).
    private var viewPopoverButton: some View {
        Button(action: {
            guard message.readAloudCapture != nil else { return }
            companionManager.openReadAloudReplayPopover(for: message)
        }) {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.inset.filled.and.person.filled")
                    .font(.system(size: 10, weight: .bold))
                Text("View")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(DS.Colors.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(
                    isHoveringViewPopover
                        ? DS.Colors.blue500.opacity(0.3)
                        : Color.white.opacity(0.06)
                )
            )
        }
        .buttonStyle(.plain)
        .disabled(message.readAloudCapture == nil)
        .opacity(message.readAloudCapture == nil ? 0.5 : 1.0)
        .onHover { hovering in
            isHoveringViewPopover = hovering
            if hovering && message.readAloudCapture != nil {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }

    // MARK: Formatters

    private func formattedDurationText(_ seconds: Double) -> String {
        if seconds < 60 {
            return String(format: "%.1fs", seconds)
        }
        let minutes = Int(seconds / 60)
        let remainderSeconds = Int(seconds.truncatingRemainder(dividingBy: 60))
        return String(format: "%dm %ds", minutes, remainderSeconds)
    }

    private var formattedTimestamp: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: message.timestamp)
    }
}

// MARK: - Screenshot Thumbnail

/// Loads and displays a single compressed screenshot from disk.
/// Shows a neutral placeholder while the image is loading or if the file is missing.
private struct ScreenshotThumbnailView: View {
    let fileURL: URL
    let onTapThumbnail: () -> Void

    @State private var thumbnailImage: NSImage? = nil
    @State private var isHoveringThumbnail = false
    @State private var ocrCaption: String? = nil

    private let thumbnailMaxHeight: CGFloat = 160
    private let thumbnailMaxWidth: CGFloat = 320

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Button(action: onTapThumbnail) {
                Group {
                    if let image = thumbnailImage {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: thumbnailMaxWidth, maxHeight: thumbnailMaxHeight)
                            .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.medium))
                    } else {
                        // Placeholder shown while the image loads or if the file is missing
                        RoundedRectangle(cornerRadius: DS.CornerRadius.medium)
                            .fill(DS.Colors.surface3)
                            .frame(width: 120, height: thumbnailMaxHeight)
                            .overlay(
                                Image(systemName: "photo")
                                    .foregroundColor(DS.Colors.textTertiary)
                            )
                    }
                }
                .background(DS.Colors.surface1)
                .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.medium))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium)
                        .stroke(
                            isHoveringThumbnail ? DS.Colors.blue500.opacity(0.6) : DS.Colors.borderSubtle,
                            lineWidth: 1
                        )
                )
                .shadow(color: Color.black.opacity(0.15), radius: 3, x: 0, y: 1)
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                isHoveringThumbnail = hovering
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }

            // OCR-extracted caption from the top of the screenshot (window title area)
            if let caption = ocrCaption {
                Text(caption)
                    .font(.system(size: 9))
                    .foregroundColor(DS.Colors.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: thumbnailMaxWidth, alignment: .trailing)
            }
        }
        .onAppear { loadThumbnailAndCaption() }
        // Reload if screenshotFileNames was updated after async compression finished
        .onChange(of: fileURL) { _ in loadThumbnailAndCaption() }
    }

    private func loadThumbnailAndCaption() {
        let url = fileURL
        Task.detached(priority: .utility) {
            guard let image = NSImage(contentsOf: url) else { return }
            await MainActor.run { thumbnailImage = image }

            // Run OCR on the top ~15% of the image to extract the window title bar text
            let caption = ScreenshotCaptionExtractor.extractCaption(from: image)
            await MainActor.run { ocrCaption = caption }
        }
    }
}

// MARK: - Screenshot Detail View

/// Larger screenshot preview shown when a chat thumbnail is clicked.
private struct ScreenshotDetailView: View {
    let fileURL: URL

    @Environment(\.dismiss) private var dismiss
    @State private var detailImage: NSImage? = nil

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    if hovering {
                        NSCursor.pointingHand.push()
                    } else {
                        NSCursor.pop()
                    }
                }
            }

            Group {
                if let detailImage {
                    GeometryReader { geometryProxy in
                        Image(nsImage: detailImage)
                            .resizable()
                            .scaledToFit()
                            .frame(
                                width: geometryProxy.size.width,
                                height: geometryProxy.size.height,
                                alignment: .center
                            )
                    }
                    .padding(8)
                    .background(DS.Colors.surface1)
                    .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.large))
                } else {
                    ProgressView()
                        .tint(DS.Colors.textSecondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .padding(12)
        .frame(minWidth: 980, minHeight: 620)
        .background(DS.Colors.background)
        .onAppear { loadDetailImage() }
        .onChange(of: fileURL) { _ in loadDetailImage() }
    }

    private func loadDetailImage() {
        let currentFileURL = fileURL
        Task.detached(priority: .utility) {
            let loadedImage = NSImage(contentsOf: currentFileURL)
            await MainActor.run {
                detailImage = loadedImage
            }
        }
    }
}

// MARK: - Typing Indicator

/// Three animated dots shown while Clicky is thinking but hasn't produced any
/// tokens yet. Disappears as soon as the first streaming character arrives.
private struct TypingIndicatorView: View {
    @State private var animationPhase = 0

    // Each dot's vertical offset follows a sine wave offset by 120° so they
    // undulate in sequence rather than all jumping at once.
    private let dotCount = 3
    private let dotSize: CGFloat = 6
    private let dotSpacing: CGFloat = 4
    private let bounceHeight: CGFloat = 4
    private let animationDuration: Double = 0.5

    var body: some View {
        HStack(spacing: dotSpacing) {
            ForEach(0..<dotCount, id: \.self) { dotIndex in
                Circle()
                    .fill(DS.Colors.textTertiary)
                    .frame(width: dotSize, height: dotSize)
                    .offset(y: dotOffset(for: dotIndex))
                    .animation(
                        .easeInOut(duration: animationDuration)
                            .repeatForever()
                            .delay(Double(dotIndex) * animationDuration / Double(dotCount)),
                        value: animationPhase
                    )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(DS.Colors.surface2)
        .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.large))
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large)
                .stroke(DS.Colors.borderSubtle, lineWidth: 1)
        )
        .onAppear {
            animationPhase = 1
        }
    }

    private func dotOffset(for dotIndex: Int) -> CGFloat {
        // animationPhase drives the bounce — 0 = rest, 1 = bounced
        // The `.delay` on each dot creates the staggered wave effect
        return animationPhase == 1 ? -bounceHeight : 0
    }
}
