//
//  SettingsWindowController.swift
//  leanring-buddy
//
//  Owns the dedicated Settings NSWindow (brain + voice configuration).
//  The app stays a menu-bar app; this is the one real window, opened on
//  demand from the top-bar panel. Shared singleton so any view can request it.
//

import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    /// Shows the Settings window (creating it on first call), bound to `companionManager`.
    func show(companionManager: CompanionManager) {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let settingsView = SettingsView(companionManager: companionManager)
        let hosting = NSHostingController(rootView: settingsView)

        let newWindow = NSWindow(contentViewController: hosting)
        newWindow.title = "joceclicky Settings"
        newWindow.styleMask = [.titled, .closable, .miniaturizable]
        newWindow.setContentSize(NSSize(width: 520, height: 560))
        newWindow.isReleasedWhenClosed = false
        newWindow.delegate = self
        newWindow.center()

        self.window = newWindow

        NSApp.activate(ignoringOtherApps: true)
        newWindow.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Keep the controller; drop the window so it's rebuilt fresh next open.
        window = nil
    }
}
