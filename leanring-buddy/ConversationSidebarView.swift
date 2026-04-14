//
//  ConversationSidebarView.swift
//  leanring-buddy
//
//  Left sidebar in the Clicky chat window showing all conversations.
//  Each row displays the conversation title and a relative timestamp.
//  A "+" button in the toolbar creates a new conversation.
//

import AppKit
import SwiftUI

struct ConversationSidebarView: View {
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 2) {
                ForEach(companionManager.conversations) { conversation in
                    ConversationRowView(
                        conversation: conversation,
                        isActive: conversation.id == companionManager.activeConversationID,
                        onSelect: { companionManager.switchToConversation(conversation.id) },
                        onDelete: { companionManager.deleteConversation(conversation.id) }
                    )
                }
            }
            .padding(.vertical, 6)
        }
        .background(DS.Colors.surface1)
    }
}

// MARK: - Conversation Row

/// A single row in the conversation sidebar. Shows the conversation title
/// (truncated to one line) and a relative timestamp. Active conversations
/// get a blue tinted background and a left accent bar.
private struct ConversationRowView: View {
    let conversation: Conversation
    let isActive: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 0) {
                // Left accent bar for the active conversation
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(isActive ? DS.Colors.accentText : Color.clear)
                    .frame(width: 3)
                    .padding(.vertical, 4)

                VStack(alignment: .leading, spacing: 2) {
                    Text(conversation.title)
                        .font(.system(size: 13, weight: isActive ? .medium : .regular))
                        .foregroundColor(isActive ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Text(relativeTimestamp)
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                .padding(.leading, 8)
                .padding(.trailing, 12)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.small)
                    .fill(rowBackground)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .contextMenu {
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
        }
        .padding(.horizontal, 6)
    }

    private var rowBackground: Color {
        if isActive { return DS.Colors.accentSubtle }
        if isHovered { return DS.Colors.surface2 }
        return Color.clear
    }

    /// Formats the conversation's last-updated date as a relative timestamp
    /// like "2h ago", "Yesterday", or "Mar 12".
    private var relativeTimestamp: String {
        let now = Date()
        let interval = now.timeIntervalSince(conversation.updatedAt)

        if interval < 60 {
            return "Just now"
        } else if interval < 3600 {
            let minutes = Int(interval / 60)
            return "\(minutes)m ago"
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            return "\(hours)h ago"
        } else if interval < 172800 {
            return "Yesterday"
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d"
            return formatter.string(from: conversation.updatedAt)
        }
    }
}
