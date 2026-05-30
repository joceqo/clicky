//
//  ActionExecutor.swift
//  leanring-buddy
//
//  The "acting" half of computer use. The brain already produces a screen
//  point (via the [POINT:x,y] tag → `detectedElementScreenLocation`); an
//  ActionExecutor turns that point into a real interaction.
//
//  This first implementation (`CGEventActionExecutor`) dispatches a synthetic
//  left-click with CGEvent — zero private APIs, only the already-granted
//  Accessibility permission. It moves the real pointer, which is fine for a
//  visible proof of the loop ("ask about the X button → buddy points → click").
//
//  Next iteration: a `BackgroundComputerUseKit`-backed executor that clicks the
//  target window in the background (no pointer takeover) via AX, resolving the
//  window + coordinate space. The library is already linked; only the wiring is
//  pending. Keeping this behind a protocol lets that executor drop in here.
//

import AppKit
import CoreGraphics

/// Performs UI actions on behalf of the buddy. Points are given in **global
/// AppKit screen coordinates** (origin at the bottom-left of the primary
/// display, Y increasing upward) — the same space as
/// `CompanionManager.detectedElementScreenLocation`.
@MainActor
protocol ActionExecutor {
    func click(atGlobalPoint appKitPoint: CGPoint, clickCount: Int)
}

@MainActor
final class CGEventActionExecutor: ActionExecutor {

    func click(atGlobalPoint appKitPoint: CGPoint, clickCount: Int) {
        let point = Self.quartzPoint(fromAppKitGlobal: appKitPoint)
        let source = CGEventSource(stateID: .combinedSessionState)
        let clicks = max(1, clickCount)

        // Move first so hover state / target window resolution is correct.
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)

        // A real double-click is two down/up pairs with an incrementing
        // clickState (1 then 2), not one pair with clickState 2 — the latter
        // doesn't register as a double-click in most apps.
        for clickState in 1...clicks {
            let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                               mouseCursorPosition: point, mouseButton: .left)
            down?.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
            down?.post(tap: .cghidEventTap)

            let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                             mouseCursorPosition: point, mouseButton: .left)
            up?.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
            up?.post(tap: .cghidEventTap)
        }
    }

    /// Converts a global AppKit point (bottom-left origin, Y up) to the global
    /// Quartz / CGEvent space (top-left origin of the primary display, Y down).
    /// The primary display is the one whose frame origin is (0, 0).
    static func quartzPoint(fromAppKitGlobal p: CGPoint) -> CGPoint {
        let primaryHeight = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.main?.frame.height
            ?? 0
        return CGPoint(x: p.x, y: primaryHeight - p.y)
    }
}
