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
    private var voiceStateCancellable: AnyCancellable?
    private var dockCancellable: AnyCancellable?

    /// True when the notch is currently on screen ONLY because the buddy is
    /// docked (it "lives in the notch" while docked). When the user undocks we
    /// hide the notch only if it was shown for this reason — so we never fight a
    /// notch the user opened manually (e.g. via `toggle()`/`show()`).
    private var shownForDock = false

    // MARK: - Response-driven presentation state

    /// True while a response is driving the notch (expanded showing the
    /// read-along). While set, the hover handler must NOT compact — the response
    /// owns the expanded state until it ends.
    private var isRespondingPresentation = false

    /// Snapshot of how the notch looked when a response STARTED, so we can put it
    /// back when the response ends.
    private enum PriorPresentation {
        case hidden    // notch wasn't on screen at all
        case compact   // pill was showing
        case expanded  // user had it open browsing tabs
    }
    private var presentationBeforeResponse: PriorPresentation = .hidden

    /// Cancellable grace task that restores the notch a beat after a response
    /// ends (so a quick follow-up response doesn't flap it).
    private var restoreTask: Task<Void, Never>?
    private let restoreGraceDelay: Duration = .milliseconds(600)

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

        // Drive the notch from voice state, independent of hover: when the buddy
        // starts responding we force-expand the notch to show the read-along;
        // when it stops we restore the prior state. SwiftUI re-renders the
        // expanded content (the router below) on the @Published phrase changes.
        voiceStateCancellable = companionManager.$voiceState
            .removeDuplicates()
            .sink { [weak self] state in
                self?.handleVoiceState(state)
            }

        // When the buddy docks, it "lives in the notch": present the compact pill
        // (which now reflects voice state). When it undocks, hide the notch again
        // — but only if WE showed it for docking, so we don't close a panel the
        // user opened manually.
        dockCancellable = companionManager.$isCursorDocked
            .removeDuplicates()
            .sink { [weak self] docked in
                self?.handleDockChange(docked)
            }

        // Seed the initial docked state (the buddy may launch already docked).
        handleDockChange(companionManager.isCursorDocked)
    }

    /// Shows the notch when docked / hides it when undocked (only if it was shown
    /// for docking). See `shownForDock`.
    private func handleDockChange(_ docked: Bool) {
        if docked {
            if !isShown {
                shownForDock = true
                show()
            }
        } else if shownForDock {
            shownForDock = false
            // Don't yank the notch out from under an active response read-along.
            if !isRespondingPresentation {
                hide()
            }
        }
    }

    /// `true` when the buddy is actively speaking a response we should render.
    private func isActivelyResponding(_ state: CompanionVoiceState) -> Bool {
        guard let companionManager else { return false }
        return state == .responding && !companionManager.currentResponsePhrases.isEmpty
    }

    /// Voice-state driven presentation: force-expand the notch to show the
    /// read-along while the buddy responds, then restore the prior state.
    private func handleVoiceState(_ state: CompanionVoiceState) {
        guard let companionManager else { return }
        if state == .responding {
            restoreTask?.cancel()
            restoreTask = nil
            guard !isRespondingPresentation else { return }
            // Remember how the notch looked so we can put it back afterwards.
            presentationBeforeResponse = isShown ? .compact : .hidden
            isRespondingPresentation = true
            isShown = true
            if notch == nil { build(companionManager: companionManager) }
            Task { await notch?.expand(on: notchScreen) }
        } else if isRespondingPresentation {
            isRespondingPresentation = false
            scheduleRestoreAfterResponse()
        }
    }

    /// Restores the notch a beat after a response ends (cancelled if a new
    /// response starts during the grace window).
    private func scheduleRestoreAfterResponse() {
        restoreTask?.cancel()
        restoreTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: self?.restoreGraceDelay ?? .milliseconds(600))
            guard let self, !Task.isCancelled, !self.isRespondingPresentation else { return }
            // If the buddy was undocked mid-response, the notch was only present
            // because of docking — hide it now that the response is done.
            if self.shownForDock, self.companionManager?.isCursorDocked == false {
                self.shownForDock = false
                self.isShown = false
                await self.notch?.hide()
                return
            }
            switch self.presentationBeforeResponse {
            case .hidden:
                self.isShown = false
                await self.notch?.hide()
            case .compact, .expanded:
                await self.notch?.compact(on: self.notchScreen)
            }
        }
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
                AnyView(NotchExpandedContent(companionManager: companionManager))
            },
            compactLeading: {
                AnyView(NotchCompactBuddy(companionManager: companionManager))
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

            // While a response owns the expanded state, never let hover compact it.
            if !expand, self.isRespondingPresentation { return }

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

/// The compact (collapsed) notch content shown as a Dynamic-Island pill in the
/// notch. Reflects the live voice state so a DOCKED buddy (which has no floating
/// desktop cursor) still gives feedback during a voice interaction:
///   • `.listening`  → a small waveform (reused `BlueCursorWaveformView`)
///   • `.processing` → a small spinner (reused `BlueCursorSpinnerView`)
///   • `.idle` / `.responding` / default → the shared `NotchBuddyGlyph` triangle
///     (visually continuous with the expanded panel header across the morph).
/// While `.responding`, the notch is force-expanded to the read-along by
/// `handleVoiceState`, so the compact content stays the triangle here (no
/// double-up). The waveform/spinner are the SAME structs the floating cursor
/// uses, kept tiny here so they fit the physical notch pill.
private struct NotchCompactBuddy: View {
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        Group {
            switch companionManager.voiceState {
            case .listening:
                BlueCursorWaveformView(audioPowerLevel: companionManager.currentAudioPowerLevel)
            case .processing:
                BlueCursorSpinnerView()
            case .idle, .responding:
                NotchBuddyGlyph()
            }
        }
        // Keep a stable, compact pill footprint regardless of which indicator is
        // showing so the notch doesn't jump as the voice state changes.
        .frame(width: 18, height: 14)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
    }
}

/// Routes the expanded notch content: the live read-along while the buddy is
/// responding, otherwise the normal 6-tab shell. SwiftUI re-renders this when
/// `voiceState` changes, so the swap is automatic.
private struct NotchExpandedContent: View {
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        if companionManager.voiceState == .responding {
            NotchResponseReadAlongView(companionManager: companionManager)
        } else {
            NotchRootView(companionManager: companionManager)
                .frame(width: 420)
        }
    }
}
