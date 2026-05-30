//
//  NotchWindowManager.swift
//  leanring-buddy
//
//  Hosts the Notch shell inside a DynamicNotchKit `DynamicNotch`, Dynamic-Island
//  style: a small COMPACT pill (the buddy triangle) sits in the notch, and
//  hovering over it EXPANDS to the full NotchRootView panel. Moving the mouse
//  away collapses it back to compact. DynamicNotchKit owns the window, notch
//  detection, and the expand/collapse animation.
//
//  DynamicNotchKit's hover behaviors only keep-visible / haptic / shadow — they
//  do NOT auto-expand — so we observe its published `isHovering` and drive
//  expand()/compact() ourselves.
//
//  Keeps the same public surface (configure / toggle / show / hide) the rest of
//  the app already calls, so CompanionManager is unchanged.
//

import AppKit
import Combine
import DynamicNotchKit
import SwiftUI

@MainActor
final class NotchWindowManager: NSObject {
    private weak var companionManager: CompanionManager?
    private var notch: DynamicNotch<AnyView, AnyView, EmptyView>?
    private var isShown = false
    private var hoverCancellable: AnyCancellable?

    /// The screen carrying the menu bar (and the notch, if any).
    private var notchScreen: NSScreen {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    // MARK: - Wiring

    /// Connects the manager to its CompanionManager. Called once by
    /// CompanionManager after init (the manager is created before `self` exists).
    func configure(companionManager: CompanionManager) {
        self.companionManager = companionManager
    }

    // MARK: - Public API

    func toggle() {
        if isShown { hide() } else { show() }
    }

    /// Presents the notch in its compact (Dynamic-Island) state. Hovering it
    /// expands to the full panel.
    func show() {
        guard let companionManager else { return }
        if notch == nil {
            build(companionManager: companionManager)
        }
        isShown = true
        Task { await notch?.compact(on: notchScreen) }
    }

    func hide() {
        guard isShown else { return }
        isShown = false
        Task { await notch?.hide() }
    }

    // MARK: - Build + hover-driven expand/compact

    private func build(companionManager: CompanionManager) {
        // `.auto` → notch style on notched Macs, floating otherwise.
        // `.keepVisible` stops the panel from vanishing mid-hover while the user
        // reaches into it; we drive expand/compact from `isHovering` below.
        let dynamicNotch = DynamicNotch<AnyView, AnyView, EmptyView>(
            hoverBehavior: [.keepVisible, .increaseShadow],
            style: .auto,
            expanded: {
                AnyView(
                    NotchRootView(companionManager: companionManager)
                        .frame(width: 420)
                )
            },
            compactLeading: {
                AnyView(NotchCompactBuddy())
            }
        )
        notch = dynamicNotch

        // Expand on hover, collapse back to compact on leave (Dynamic Island UX).
        hoverCancellable = dynamicNotch.$isHovering
            .removeDuplicates()
            .sink { [weak self] hovering in
                guard let self else { return }
                Task { @MainActor in
                    guard self.isShown, let notch = self.notch else { return }
                    if hovering {
                        await notch.expand(on: self.notchScreen)
                        // FIRST-CLICK FIX: the DynamicNotch panel is a
                        // .nonactivatingPanel, so the *first* click inside it is
                        // normally eaten making the window key instead of hitting
                        // the SwiftUI button (the classic "double click to switch
                        // tab" bug). By making the panel key the moment the user
                        // hovers — before they click — the click lands on the tab
                        // button directly. `acceptsFirstMouse` on the hosting view
                        // (see FirstMouseView in NotchRootView) covers the rest.
                        notch.windowController?.window?.makeKey()
                    } else {
                        await notch.compact(on: self.notchScreen)
                    }
                }
            }
    }
}

/// The compact (collapsed) notch content: the buddy's little triangle, shown as
/// a Dynamic-Island pill in the notch. Uses the shared `NotchBuddyGlyph` so the
/// triangle is visually continuous with the expanded panel's header glyph (see
/// NotchBuddyGlyph.swift / NotchRootView) across the compact → expanded morph.
private struct NotchCompactBuddy: View {
    var body: some View {
        NotchBuddyGlyph()
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
    }
}
