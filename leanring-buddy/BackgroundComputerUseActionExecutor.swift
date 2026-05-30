//
//  BackgroundComputerUseActionExecutor.swift
//  leanring-buddy
//
//  A precise, *background* ActionExecutor backed by the BackgroundComputerUseKit
//  SwiftPM package (module `BackgroundComputerUse`). Unlike `CGEventActionExecutor`,
//  this never moves the real pointer or steals focus — it resolves the window
//  under the requested point and dispatches an AX/native background click scoped
//  to that window (visualCursor: .disabled).
//
//  ── Coordinate spaces (the tricky part) ───────────────────────────────────
//  Our protocol hands us a GLOBAL AppKit screen point: origin bottom-left of the
//  primary display, Y increasing UP, in logical points.
//
//  The library's coordinate-based `ClickRequest(window:x:y:)` does NOT carry a
//  coordinate-space field. Inspecting the runtime
//  (ClickRouteService.executeCoordinateClick → coordinatePlan(x:y:modelSize:…),
//  source "direct_model_facing_coordinate", inputCoordinateSpace
//  `.modelFacingScreenshot`) shows it interprets x/y as **modelFacingScreenshot
//  pixels**: the window-fit screenshot's pixel space, TOP-LEFT origin, Y down.
//  The library converts those pixels back to a global AppKit point with:
//
//      scaleX = modelW / frame.width        (frame == window.frameAppKit, bottom-left)
//      scaleY = modelH / frame.height
//      appKit.x = frame.minX + (x / scaleX)
//      appKit.y = frame.maxY - (y / scaleY)   // maxY = frame.y + frame.height
//
//  We invert that to turn our global AppKit point into modelFacingScreenshot
//  pixels for the chosen window:
//
//      x_model = (appKit.x - frame.minX) * scaleX
//      y_model = (frame.maxY - appKit.y) * scaleY
//
//  modelW/modelH come from `ScreenshotFitRule().predictedModelSize(for:)` — the
//  exact same fit rule the library uses — so the scale factor is identical on
//  both sides and the round-trip is lossless regardless of the model size value.
//  (The Y axis is flipped: AppKit bottom-left → screenshot top-left.)
//
//  This is a coordinate click (not a semantic AX node click). The semantic
//  `target: .nodeID(...)` path would need traversal of the AX semantic tree to
//  find the node at the point — left out deliberately to keep this drop-in and
//  robust; the coordinate click is already window-targeted and background-safe.
//

import AppKit
import BackgroundComputerUse
import CoreGraphics

@MainActor
final class BackgroundComputerUseActionExecutor: ActionExecutor {

    /// `.disabled` visual cursor = no pointer takeover, the whole point of this executor.
    private let runtime = BackgroundComputerUseRuntime(options: .init(visualCursor: .disabled))

    func click(atGlobalPoint appKitPoint: CGPoint, clickCount: Int) {
        let clicks = max(1, clickCount)

        guard let resolved = resolveWindow(under: appKitPoint) else {
            print("🪟 BCU click: no window found under global AppKit (\(Int(appKitPoint.x)), \(Int(appKitPoint.y))).")
            return
        }
        let window = resolved.window
        let frame = resolved.frameAppKit

        // Invert the library's modelFacingScreenshot → AppKit mapping.
        let modelSize = ScreenshotFitRule().predictedModelSize(
            for: GlobalEventTapTopLeftRect(
                x: frame.minX, y: frame.minY, width: frame.width, height: frame.height
            )
        )
        guard frame.width > 0, frame.height > 0, modelSize.width > 0, modelSize.height > 0 else {
            print("🪟 BCU click: window \"\(window.title)\" has a degenerate frame; aborting.")
            return
        }
        let scaleX = Double(modelSize.width) / Double(frame.width)
        let scaleY = Double(modelSize.height) / Double(frame.height)
        // AppKit bottom-left (Y up) → modelFacingScreenshot top-left (Y down).
        let xModel = (Double(appKitPoint.x) - Double(frame.minX)) * scaleX
        let yModel = (Double(frame.maxY) - Double(appKitPoint.y)) * scaleY

        let request = ClickRequest(
            window: window.windowID,
            x: xModel,
            y: yModel,
            mode: clicks >= 2 ? .double : .single,
            clickCount: clicks
        )

        do {
            let response = try runtime.click(request)
            print("🪟 BCU click → window \"\(window.title)\" [\(window.bundleID)] id=\(window.windowID) "
                + "modelPx=(\(Int(xModel)), \(Int(yModel))) clicks=\(clicks) — "
                + "ok=\(response.ok) route=\(response.finalRoute.rawValue) summary=\"\(response.summary)\"")
        } catch {
            print("🪟 BCU click failed: \(error)")
        }
    }

    // MARK: - Window resolution

    private struct ResolvedTarget {
        let window: WindowDTO
        let frameAppKit: CGRect
    }

    /// Picks the on-screen window whose AppKit frame contains the point. Prefers
    /// the frontmost app's windows; falls back to scanning every running app.
    /// Among multiple matches the smallest-area window wins (most specific).
    private func resolveWindow(under appKitPoint: CGPoint) -> ResolvedTarget? {
        let apps = runtime.listApps()

        // Search the frontmost app first, then everyone else.
        var orderedNames: [String] = []
        if let frontmost = apps.frontmostApp?.name { orderedNames.append(frontmost) }
        for app in apps.runningApps where app.onscreenWindowCount > 0 {
            if !orderedNames.contains(app.name) { orderedNames.append(app.name) }
        }

        var best: ResolvedTarget?
        var bestArea = Double.greatestFiniteMagnitude

        for name in orderedNames {
            guard let windows = try? runtime.listWindows(ListWindowsRequest(app: name)).windows else { continue }
            for window in windows where window.isOnScreen && !window.isMinimized {
                let f = window.frameAppKit
                let rect = CGRect(x: f.x, y: f.y, width: f.width, height: f.height)
                guard rect.width > 0, rect.height > 0, rect.contains(appKitPoint) else { continue }
                let area = Double(rect.width * rect.height)
                // Frontmost app's first matching window already wins ties by being
                // scanned first; otherwise prefer the most specific (smallest) hit.
                if best == nil || area < bestArea {
                    best = ResolvedTarget(window: window, frameAppKit: rect)
                    bestArea = area
                }
            }
            // If the frontmost app produced a hit, trust it and stop early.
            if best != nil, name == apps.frontmostApp?.name { break }
        }
        return best
    }
}
