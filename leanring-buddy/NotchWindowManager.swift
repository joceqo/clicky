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

    /// Pending hover-driven transition (cancellable so we can debounce). Only one
    /// is ever in flight; a new hover event cancels the previous pending task.
    private var hoverTransitionTask: Task<Void, Never>?

    /// Hover-intent delay before EXPANDING — merely passing the cursor near the
    /// pill shouldn't expand; the user must dwell briefly.
    private let expandIntentDelay: Duration = .milliseconds(150)

    /// Close delay before COMPACTING — a brief exit while reaching across the
    /// panel shouldn't collapse it, but a genuine leave does. Re-entering cancels
    /// the pending compact.
    private let compactCloseDelay: Duration = .milliseconds(300)

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
        hoverTransitionTask?.cancel()
        hoverTransitionTask = nil
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

        // Expand on hover, collapse back to compact on leave (Dynamic-Island UX).
        //
        // We rely on DynamicNotchKit's own `isHovering` (it already tracks the
        // panel's true hover bounds and de-dupes via removeDuplicates below), but
        // we DEBOUNCE both directions to make it intentional and to break the
        // expand→bigger-window→still-hovering feedback loop:
        //   • EXPAND only after a short dwell (expandIntentDelay) so passing the
        //     cursor near the pill doesn't trigger it.
        //   • COMPACT only after a grace period (compactCloseDelay) so a brief
        //     exit while reaching across the panel doesn't collapse it; if the
        //     cursor returns, isHovering flips back to true, which cancels the
        //     pending compact below.
        // Each hover change cancels the previous pending task, so stale toggles
        // near the boundary can't fire.
        hoverCancellable = dynamicNotch.$isHovering
            .removeDuplicates()
            .sink { [weak self] hovering in
                self?.scheduleHoverTransition(expand: hovering)
            }
    }

    /// Debounced hover handler — see the comment at the call site. Cancels any
    /// in-flight transition, waits the appropriate delay, then re-checks
    /// `isHovering` so a value that flipped back during the delay is ignored.
    private func scheduleHoverTransition(expand: Bool) {
        hoverTransitionTask?.cancel()
        hoverTransitionTask = Task { @MainActor [weak self] in
            guard let self, let notch = self.notch else { return }
            let delay = expand ? self.expandIntentDelay : self.compactCloseDelay
            try? await Task.sleep(for: delay)

            // Bail if cancelled (a newer hover event arrived), the notch was
            // hidden, or the hover state no longer matches our intent.
            guard !Task.isCancelled, self.isShown, notch.isHovering == expand else { return }

            if expand {
                await notch.expand(on: self.notchScreen)
                // FIRST-CLICK FIX: the DynamicNotch panel is a .nonactivatingPanel,
                // so the first click inside it would otherwise be eaten making the
                // window key instead of hitting the SwiftUI button (the "double
                // click to switch tab" bug). Make the panel key now — after the
                // dwell, before the user clicks — so the click lands on the button.
                // Done after expand() so it doesn't perturb the initial hover
                // tracking that drives this very transition.
                notch.windowController?.window?.makeKey()
            } else {
                await notch.compact(on: self.notchScreen)
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
