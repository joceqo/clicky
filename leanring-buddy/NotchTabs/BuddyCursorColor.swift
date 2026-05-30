//
//  BuddyCursorColor.swift
//  leanring-buddy
//
//  The user-selectable color of the buddy cursor triangle. Persisted via
//  UserDefaults under "buddyCursorColor" and surfaced in the Notch Home tab as
//  four triangle swatches (matching the commercial Clicky "Cursor color" row).
//
//  The choice is LIVE: OverlayWindow's BlueCursorView reads `BuddyCursorColor`
//  through an @AppStorage so picking a swatch immediately recolors the on-screen
//  cursor (and the compact / expanded notch glyph).
//

import SwiftUI

/// Persisted key for the chosen buddy cursor color. Shared so OverlayWindow,
/// the Home tab, and the notch glyph all read/write the same default.
let buddyCursorColorKey = "buddyCursorColor"

/// The set of selectable buddy cursor colors. Raw value is the persisted string.
enum BuddyCursorColor: String, CaseIterable, Identifiable {
    case blue
    case indigo
    case yellow
    case green

    var id: String { rawValue }

    /// The SwiftUI color used to fill the triangle.
    var color: Color {
        switch self {
        case .blue:   return DS.Colors.overlayCursorBlue          // #3380FF (default)
        case .indigo: return Color(hex: "#6E56CF")                // Radix Indigo-ish
        case .yellow: return DS.Colors.warning                    // #FFB224
        case .green:  return DS.Colors.success                    // #34D399
        }
    }

    /// The currently persisted color (falls back to blue). Read from any
    /// non-SwiftUI context (e.g. the default for `NotchBuddyGlyph`).
    static var current: BuddyCursorColor {
        let raw = UserDefaults.standard.string(forKey: buddyCursorColorKey)
        return raw.flatMap(BuddyCursorColor.init(rawValue:)) ?? .blue
    }
}
