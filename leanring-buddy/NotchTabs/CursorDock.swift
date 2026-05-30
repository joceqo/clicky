//
//  CursorDock.swift
//  leanring-buddy
//
//  "Dock the cursor" — parks the buddy triangle at a fixed anchor near the
//  notch instead of having it follow the mouse. This is DISTINCT from
//  DockVisibility ("Show in Dock", the macOS Dock icon): this feature docks the
//  CURSOR BUDDY, not the app's Dock presence.
//
//  Mirrors the commercial Clicky shape: a persisted bool, a fly-to-anchor on
//  dock, and a fly-back-and-resume-following on undock. The anchor is the
//  "dock button anchor" near the notch — for v1 it is a FIXED top-center point
//  just below the menu bar / notch strip on the notch (or main) screen.
//
//  TODO: capture the Notch Home tab's Dock button on-screen anchor via a
//  `DockButtonAnchorPreferenceKey` so the buddy flies to the exact button
//  position rather than a fixed top-center point.
//

import AppKit
import SwiftUI

/// Persisted key for whether the cursor buddy is docked (parked at the notch
/// anchor). Versioned (`.v2`) to match Clicky's `clicky.cursor.docked.v2` shape.
let buddyCursorDockedKey = "clicky.cursor.docked.v2"

enum CursorDock {
    /// The screen that carries the menu bar / notch. The buddy parks here so the
    /// dock anchor is always reachable and consistent across multi-display setups.
    /// Prefers a notched display, then the main screen, then the first screen.
    @MainActor
    static var dockScreen: NSScreen {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    /// The dock anchor as a GLOBAL AppKit screen point (bottom-left origin — the
    /// same space as `NSEvent.mouseLocation`, which BlueCursorView converts to
    /// SwiftUI coordinates). Top-center of the dock screen, just below the menu
    /// bar / notch strip.
    ///
    /// `frame.midX` keeps it centered under the notch; `visibleFrame.maxY`
    /// drops it just below the menu bar. On notched Macs the notch eats into the
    /// top safe area, so we nudge down by the safe-area top inset so the buddy
    /// sits BELOW the notch strip rather than behind it.
    @MainActor
    static func anchorScreenPoint(on screen: NSScreen) -> CGPoint {
        let frame = screen.frame
        let visible = screen.visibleFrame
        let notchInset = screen.safeAreaInsets.top

        let x = frame.midX
        // visibleFrame.maxY is the top of the usable area (below the menu bar).
        // Subtract a small gap plus the notch inset so the buddy parks just under
        // the notch/menu-bar strip.
        let y = visible.maxY - 12 - notchInset

        return CGPoint(x: x, y: y)
    }

    /// The currently persisted docked state (defaults to false → following).
    static var isDocked: Bool {
        UserDefaults.standard.bool(forKey: buddyCursorDockedKey)
    }
}
