//
//  ChatView.swift
//  leanring-buddy
//
//  SwiftUI chat window UI. Shows the full conversation history (voice + text
//  exchanges), lets the user type new messages, and streams Claude's response
//  in-place as tokens arrive. Both voice and text messages appear here so the
//  user has a single place to review what was said and what Clicky answered.
//

import SwiftUI

// MARK: - Root View

struct ChatView: View {
    @ObservedObject var companionManager: CompanionManager
    @State private var inputText = ""

    var body: some View {
        VStack(spacing: 0) {
            chatHeaderBar
            dividerLine
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

    // MARK: - Header

    private var chatHeaderBar: some View {
        HStack(spacing: 8) {
            Text("Clicky")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)

            Spacer()

            // Show the active model so the user knows which Claude they're talking to
            Text(modelDisplayName)
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
        }
        .padding(.horizontal, 16)
        // Extra top padding to clear the traffic-light buttons in the transparent title bar
        .padding(.top, 16)
        .padding(.bottom, 10)
        .background(DS.Colors.surface1)
    }

    private var modelDisplayName: String {
        switch companionManager.selectedModel {
        case "claude-opus-4-6":   return "Opus 4.6"
        case "claude-sonnet-4-6": return "Sonnet 4.6"
        case "local":             return "Apple Intelligence"
        case "lmstudio":          return "LM Studio"
        default:                  return companionManager.selectedModel
        }
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
                        ChatMessageBubbleView(message: message)
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
private struct ChatMessageBubbleView: View {
    let message: ChatMessage

    var body: some View {
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

    // MARK: User bubble

    private var userBubble: some View {
        VStack(alignment: .trailing, spacing: 4) {
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

    // MARK: Timestamp + source badge

    private func bottomMetaRow(role: ChatMessageRole) -> some View {
        HStack(spacing: 4) {
            if role == .user && message.source == .voice {
                // Mic badge signals this message came from push-to-talk, not typing
                Image(systemName: "mic.fill")
                    .font(.system(size: 9))
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
        }
    }

    private var formattedTimestamp: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: message.timestamp)
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
