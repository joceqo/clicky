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

            ToolbarItem(placement: .automatic) {
                Button {
                    if let activeID = companionManager.activeConversationID {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(activeID.uuidString, forType: .string)
                    }
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .help("Copy Chat ID")
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
    }

    private var activeConversationTitle: String {
        guard let activeID = companionManager.activeConversationID,
              let conversation = companionManager.conversations.first(where: { $0.id == activeID })
        else { return "Clicky" }
        return conversation.title
    }


}
