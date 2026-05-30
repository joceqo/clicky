//
//  DockVisibility.swift
//  leanring-buddy
//
//  Controls whether Clicky shows a Dock icon. The app ships as an LSUIElement
//  (menu-bar / notch only, .accessory activation policy). "Dock Clicky" flips
//  the live NSApplication.activationPolicy to .regular and persists the choice;
//  "Undock Clicky" flips it back to .accessory. Both the Home tab's
//  Dock/Undock button and the Settings tab's "Show in Dock" toggle drive the
//  same persisted key so they stay in sync.
//

import AppKit
import SwiftUI

/// Persisted key for the Dock-visibility preference.
let showInDockKey = "showInDock"

enum DockVisibility {
    /// Applies the persisted preference to the live activation policy.
    /// Call once on launch and whenever the preference changes.
    @MainActor
    static func apply(showInDock: Bool) {
        // .regular shows a Dock icon + app menu; .accessory keeps Clicky as a
        // menu-bar/notch-only agent (the default LSUIElement behavior).
        NSApp.setActivationPolicy(showInDock ? .regular : .accessory)
    }

    /// The currently persisted preference (defaults to false → notch only).
    static var isShownInDock: Bool {
        UserDefaults.standard.bool(forKey: showInDockKey)
    }
}
