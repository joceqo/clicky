//
//  ChatContainerView.swift
//  leanring-buddy
//
//  Root view for the Clicky chat window. Uses NavigationSplitView to
//  provide a toggleable conversation sidebar (left) and the chat view
//  (right). The toolbar holds the sidebar toggle, new chat button,
//  copy-chat-id, and a gear that opens the shared Settings window.
//

import SwiftUI

struct ChatContainerView: View {
    @ObservedObject var companionManager: CompanionManager
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .automatic

    var body: some View {
        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            ConversationSidebarView(companionManager: companionManager)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            ChatView(companionManager: companionManager)
        }
        .navigationSplitViewStyle(.balanced)
        .navigationTitle(activeConversationTitle)
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
                    SettingsWindowController.shared.show(companionManager: companionManager)
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("Settings")
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
