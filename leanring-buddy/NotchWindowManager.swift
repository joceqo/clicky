//
//  NotchWindowManager.swift
//  leanring-buddy
//
//  Owns a borderless, non-activating NSPanel anchored under the hardware notch
//  (top-center of the built-in display, below the menu bar). On displays without
//  a notch it anchors top-center just below the menu bar. The panel hosts a
//  SwiftUI shell (NotchRootView) via NSHostingView.
//
//  Mirrors the KeyablePanel pattern from MenuBarPanelManager so text fields can
//  receive focus while the panel stays non-activating (does not steal focus from
//  the user's current app). Repositions on screen-parameter changes.
//
//  No private APIs: the notch is detected via NSScreen.safeAreaInsets /
//  auxiliaryTopLeftArea (public AppKit), with a top-center fallback.
//

import AppKit
import SwiftUI

/// NSPanel subclass that can become the key window even when borderless and
/// non-activating, so embedded text fields can receive focus.
private final class NotchKeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class NotchWindowManager: NSObject {
    private weak var companionManager: CompanionManager?
    private var panel: NSPanel?
    private var screenParamsObserver: NSObjectProtocol?

    private let panelWidth: CGFloat = 420
    private let panelHeight: CGFloat = 320
    /// Gap left on either side of the hardware notch so the panel tucks under it.
    private let gapBelowMenuBar: CGFloat = 6

    // MARK: - Wiring

    /// Connects the manager to its CompanionManager. Called once by
    /// CompanionManager after init (the manager is created before `self` exists).
    func configure(companionManager: CompanionManager) {
        self.companionManager = companionManager

        if screenParamsObserver == nil {
            screenParamsObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.repositionIfVisible()
                }
            }
        }
    }

    deinit {
        if let observer = screenParamsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Public API

    func toggle() {
        if let panel, panel.isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        guard let companionManager else { return }
        if panel == nil {
            createPanel(companionManager: companionManager)
        }
        positionPanel()
        panel?.makeKeyAndOrderFront(nil)
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    // MARK: - Panel Lifecycle

    private func createPanel(companionManager: CompanionManager) {
        let rootView = NotchRootView(companionManager: companionManager)
            .frame(width: panelWidth)

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        let notchPanel = NotchKeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        notchPanel.isFloatingPanel = true
        notchPanel.level = .floating
        notchPanel.isOpaque = false
        notchPanel.backgroundColor = .clear
        notchPanel.hasShadow = false
        notchPanel.hidesOnDeactivate = false
        notchPanel.isExcludedFromWindowsMenu = true
        notchPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        notchPanel.isMovableByWindowBackground = false
        notchPanel.titleVisibility = .hidden
        notchPanel.titlebarAppearsTransparent = true

        notchPanel.contentView = hostingView
        panel = notchPanel
    }

    private func repositionIfVisible() {
        guard let panel, panel.isVisible else { return }
        positionPanel()
    }

    // MARK: - Positioning

    /// The screen carrying the menu bar (and the notch, if any). On a notched
    /// MacBook this is the built-in display.
    private var notchScreen: NSScreen? {
        // The screen at index 0 (or `.main`) owns the menu bar in the typical
        // single-notch setup. Prefer the screen reporting a non-zero top safe
        // area (the notch), else fall back to the main screen.
        if let notched = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) {
            return notched
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    private func positionPanel() {
        guard let panel, let screen = notchScreen else { return }

        let fittingSize = panel.contentView?.fittingSize
            ?? CGSize(width: panelWidth, height: panelHeight)
        let actualHeight = fittingSize.height

        let visible = screen.visibleFrame   // excludes the menu bar
        let full = screen.frame

        // Horizontal center on the screen.
        let originX = full.midX - (panelWidth / 2)

        // The top edge to anchor under. With a notch, `auxiliaryTopLeftArea`
        // (when available) gives the usable area below the menu bar; otherwise
        // the visibleFrame's top already sits below the menu bar. We tuck the
        // panel just under that line.
        let topAnchorY: CGFloat
        if #available(macOS 12.0, *), screen.safeAreaInsets.top > 0 {
            // Notched display: place directly under the notch / menu bar.
            // visibleFrame.maxY is below the menu bar; the notch occupies the
            // menu-bar strip, so anchoring under visibleFrame keeps us clear of it.
            topAnchorY = visible.maxY - gapBelowMenuBar
        } else {
            // Non-notch display: anchor top-center below the menu bar.
            topAnchorY = visible.maxY - gapBelowMenuBar
        }

        let originY = topAnchorY - actualHeight

        panel.setFrame(
            NSRect(x: originX, y: originY, width: panelWidth, height: actualHeight),
            display: true
        )
    }
}
