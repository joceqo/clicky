//
//  ChatContainerView.swift
//  leanring-buddy
//
//  Root view for the Clicky chat window. Uses NavigationSplitView to
//  provide a toggleable conversation sidebar (left) and the chat view
//  or settings page (right). The toolbar holds the sidebar toggle,
//  new chat button, model name, and gear icon.
//

import SwiftUI
import SwiftGrab

struct ChatContainerView: View {
    @ObservedObject var companionManager: CompanionManager
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .automatic
    @State private var isShowingSettings = false

    var body: some View {
        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            ConversationSidebarView(companionManager: companionManager)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            if isShowingSettings {
                ChatSettingsView(
                    companionManager: companionManager,
                    onDismiss: { isShowingSettings = false }
                )
            } else {
                ChatView(companionManager: companionManager)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .navigationTitle(isShowingSettings ? "Settings" : activeConversationTitle)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    withAnimation {
                        if sidebarVisibility == .detailOnly {
                            sidebarVisibility = .all
                        } else {
                            sidebarVisibility = .detailOnly
                        }
                    }
                } label: {
                    Image(systemName: "sidebar.leading")
                }
                .help("Toggle Sidebar")
            }

            ToolbarItem(placement: .automatic) {
                Button(action: {
                    isShowingSettings = false
                    companionManager.createNewConversation()
                }) {
                    Image(systemName: "square.and.pencil")
                }
                .help("New Chat")
            }

            ToolbarItem(placement: .status) {
                HStack(spacing: 4) {
                    modelIconView
                    Text(modelDisplayName)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .help("⌃M to switch model")
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    isShowingSettings.toggle()
                } label: {
                    Image(systemName: isShowingSettings ? "gearshape.fill" : "gearshape")
                }
                .help(isShowingSettings ? "Back to Chat" : "Settings")
            }
        }
        .swiftGrab(enabled: true, mode: .appLocal) { _ in }
    }

    private var activeConversationTitle: String {
        guard let activeID = companionManager.activeConversationID,
              let conversation = companionManager.conversations.first(where: { $0.id == activeID })
        else { return "Clicky" }
        return conversation.title
    }

    @ViewBuilder
    private var modelIconView: some View {
        switch companionManager.selectedModel {
        case "claude-opus-4-6", "claude-sonnet-4-6":
            Image("icon-anthropic").resizable().scaledToFit().frame(width: 14, height: 14)
        case "lmstudio":
            Image("icon-lmstudio").resizable().scaledToFit().frame(width: 14, height: 14)
        case "local":
            Image(systemName: "apple.logo").font(.system(size: 12))
        default:
            EmptyView()
        }
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

}
