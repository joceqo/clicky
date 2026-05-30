//
//  NotchThreadsTab.swift
//  leanring-buddy
//
//  The Notch "Threads" surface: lists conversations from the existing
//  ConversationStore (via CompanionManager.conversations). Each row shows the
//  title and last-updated time. Tapping a row switches to that conversation and
//  opens the windowed chat. Empty state via DSCard.
//

import SwiftUI

struct NotchThreadsTab: View {
    @ObservedObject var companionManager: CompanionManager

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            HStack {
                Text("Conversations")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                Spacer()
                Button {
                    companionManager.openChatWindow()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(DS.Colors.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open chat")
            }

            if companionManager.conversations.isEmpty {
                DSCard {
                    VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                        Text("No conversations yet")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(DS.Colors.textPrimary)
                        Text("Start a chat to see your threads here.")
                            .font(.system(size: 12))
                            .foregroundColor(DS.Colors.textSecondary)
                    }
                }
            } else {
                ScrollView {
                    VStack(spacing: DS.Spacing.sm) {
                        ForEach(companionManager.conversations) { conversation in
                            threadRow(conversation)
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
        }
    }

    private func threadRow(_ conversation: Conversation) -> some View {
        Button {
            companionManager.switchToConversation(conversation.id)
            companionManager.openChatWindow()
        } label: {
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: "bubble.left.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(conversation.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(1)
                    Text(Self.relativeFormatter.localizedString(
                        for: conversation.updatedAt, relativeTo: Date()))
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .padding(.vertical, DS.Spacing.sm)
            .padding(.horizontal, DS.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(DS.Colors.surface2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(conversation.title)
    }
}
