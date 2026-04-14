//
//  ChatWindowController.swift
//  leanring-buddy
//
//  Manages the lifecycle of the Clicky chat window.
//  The window is created lazily on first show and kept alive after being
//  closed (isReleasedWhenClosed=false) so reopening it is instant — no
//  SwiftUI view re-initialization or lost scroll position.
//

import AppKit
import SwiftUI

@MainActor
final class ChatWindowController: NSObject, NSWindowDelegate {
    private var chatWindow: NSWindow?
    private let companionManager: CompanionManager

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        super.init()
    }

    /// Shows the chat window, creating it on first call.
    /// If the window is minimized to the Dock, unminimizes it first.
    func showChatWindow() {
        guard let existingWindow = chatWindow else {
            createAndShowChatWindow()
            return
        }

        if existingWindow.isMiniaturized {
            existingWindow.deminiaturize(nil)
        }
        existingWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func createAndShowChatWindow() {
        let chatView = ChatView(companionManager: companionManager)
        let hostingController = NSHostingController(rootView: chatView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "Clicky"
        window.setContentSize(NSSize(width: 660, height: 540))
        window.minSize = NSSize(width: 440, height: 400)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        // Keep the window alive after closing so the conversation persists and
        // reopening is instant. The user must Quit the app to fully discard the window.
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // Match the app's dark background so the title bar blends with the content header
        window.backgroundColor = NSColor(red: 0x17 / 255.0, green: 0x19 / 255.0, blue: 0x18 / 255.0, alpha: 1)
        window.appearance = NSAppearance(named: .darkAqua)
        window.center()

        chatWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
