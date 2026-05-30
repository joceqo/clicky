//
//  NotchBuddyGlyph.swift
//  leanring-buddy
//
//  The buddy's little upward triangle, shared by BOTH the compact notch pill
//  (NotchWindowManager → NotchCompactBuddy) and the expanded panel header
//  (NotchRootView). Keeping a single source of truth means the triangle reads as
//  one continuous element across the compact → expanded morph instead of
//  disappearing mid-animation.
//

import SwiftUI

/// A simple upward triangle matching the buddy cursor's silhouette.
struct NotchTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// The buddy glyph: the upward triangle filled with the user's chosen cursor
/// color. Used at a small size in the compact pill and the expanded header so
/// the morph reads as continuous.
struct NotchBuddyGlyph: View {
    /// Resolved fill color. Defaults to the live overlay-cursor color so the
    /// glyph matches the on-screen buddy.
    var color: Color = BuddyCursorColor.current.color
    var width: CGFloat = 13
    var height: CGFloat = 11

    var body: some View {
        NotchTriangle()
            .fill(color)
            .frame(width: width, height: height)
            .accessibilityLabel("Clicky")
    }
}
