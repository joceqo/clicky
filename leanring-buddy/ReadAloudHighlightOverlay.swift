//
//  ReadAloudHighlightOverlay.swift
//  leanring-buddy
//
//  Sentence-level highlight overlay used during ⌃⇧L read-aloud.
//
//  When Supertonic begins playing each synthesized sentence, the manager moves
//  a small borderless transparent NSPanel to cover that sentence's bounding box
//  on screen and paints a translucent yellow rectangle inside. As the next
//  sentence starts, the panel jumps to that sentence's box. When playback ends
//  or is cancelled, the panel is hidden.
//
//  The panel is non-activating and ignores mouse events so it floats above
//  every other window — including full-screen apps — without stealing focus
//  or blocking clicks underneath.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class ReadAloudHighlightOverlayManager: ObservableObject {
    private var highlightPanel: NSPanel?
    /// Visual style for the live highlight. Read by the SwiftUI view via the
    /// shared style model so the overlay redraws when the preference changes
    /// mid-session.
    private let styleModel = ReadAloudHighlightStyleModel()

    /// Updates the on-screen highlight style (`"highlight"` or `"underline"`).
    /// Safe to call while a read-aloud is in progress — the SwiftUI view
    /// re-renders on the next frame without recreating the panel.
    func setHighlightStyle(_ style: String) {
        styleModel.style = style
    }

    /// Shows the highlight rectangle covering the given screen rect (AppKit
    /// coords, bottom-left origin). Creates the panel lazily on first call.
    func showHighlight(coveringScreenRect screenRect: CGRect) {
        guard screenRect.width > 0, screenRect.height > 0 else {
            hide()
            return
        }

        let panel = ensurePanel()

        // Add a small padding around the text so the highlight isn't pixel-tight
        // against the glyphs — looks much more like a real reading highlighter.
        let paddedRect = screenRect.insetBy(dx: -4, dy: -3)

        panel.setFrame(paddedRect, display: true)
        panel.orderFrontRegardless()
    }

    /// Hides the highlight panel without destroying it — fast to bring back.
    func hide() {
        highlightPanel?.orderOut(nil)
    }

    private func ensurePanel() -> NSPanel {
        if let highlightPanel { return highlightPanel }

        let initialFrame = NSRect(x: 0, y: 0, width: 1, height: 1)
        let panel = NSPanel(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isExcludedFromWindowsMenu = true

        let hostingView = NSHostingView(rootView: ReadAloudHighlightView(styleModel: styleModel))
        hostingView.frame = initialFrame
        panel.contentView = hostingView

        highlightPanel = panel
        return panel
    }
}

/// Observable wrapper so the SwiftUI highlight view re-renders when the
/// user flips the style toggle in Settings without having to recreate the
/// panel or reinstall the hosting view.
@MainActor
final class ReadAloudHighlightStyleModel: ObservableObject {
    /// `"highlight"` (filled yellow rectangle) or `"underline"` (thin bar
    /// along the bottom). Any other value falls back to `"highlight"`.
    @Published var style: String = UserDefaults.standard.string(forKey: "readAloudHighlightStyle") ?? "highlight"
}

private struct ReadAloudHighlightView: View {
    @ObservedObject var styleModel: ReadAloudHighlightStyleModel

    var body: some View {
        if styleModel.style == "underline" {
            // Underline: thin yellow bar at the bottom edge with a soft glow.
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                Rectangle()
                    .fill(Color.yellow.opacity(0.9))
                    .frame(height: 2)
                    .shadow(color: Color.yellow.opacity(0.6), radius: 2, x: 0, y: 0)
            }
        } else {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.yellow.opacity(0.32))
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(Color.yellow.opacity(0.55), lineWidth: 1)
                )
        }
    }
}

@MainActor
final class ReadAloudTextPopoverOverlayManager: ObservableObject {
    private var textPopoverPanel: NSPanel?
    private let viewModel = ReadAloudTextPopoverViewModel()

    func show(fullText: String) {
        guard !fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            hide()
            return
        }
        viewModel.fullText = fullText
        viewModel.currentWordRange = nil

        let panel = ensurePanel()
        positionPanelNearTopCenter(panel)
        panel.orderFrontRegardless()
    }

    func updateCurrentWord(characterRange: NSRange?) {
        viewModel.currentWordRange = characterRange
    }

    func hide() {
        viewModel.currentWordRange = nil
        textPopoverPanel?.orderOut(nil)
    }

    private func ensurePanel() -> NSPanel {
        if let textPopoverPanel { return textPopoverPanel }

        let panelWidth: CGFloat = 440
        let panelHeight: CGFloat = 150
        let initialFrame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
        let panel = NSPanel(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isExcludedFromWindowsMenu = true

        let hostingView = NSHostingView(rootView: ReadAloudTextPopoverView(viewModel: viewModel))
        hostingView.frame = initialFrame
        panel.contentView = hostingView
        textPopoverPanel = panel
        return panel
    }

    private func positionPanelNearTopCenter(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let panelWidth = panel.frame.width
        let panelHeight = panel.frame.height
        let originX = screen.frame.midX - panelWidth / 2
        let originY = screen.frame.maxY - panelHeight - 74
        panel.setFrame(
            NSRect(x: originX, y: originY, width: panelWidth, height: panelHeight),
            display: true
        )
    }
}

@MainActor
private final class ReadAloudTextPopoverViewModel: ObservableObject {
    @Published var fullText: String = ""
    @Published var currentWordRange: NSRange?
}

private struct ReadAloudTextPopoverView: View {
    @ObservedObject var viewModel: ReadAloudTextPopoverViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Reading")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(DS.Colors.textTertiary)

            ScrollView {
                highlightedText
                    .font(.system(size: 14, weight: .regular))
                    .foregroundColor(DS.Colors.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.disabled)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 440, height: 150)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(DS.Colors.background.opacity(0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 0.8)
                )
                .shadow(color: Color.black.opacity(0.35), radius: 10, x: 0, y: 6)
        )
    }

    private var highlightedText: Text {
        guard let currentWordRange = viewModel.currentWordRange else {
            return Text(trimmedPreviewText(from: viewModel.fullText))
        }
        let fullNSString = viewModel.fullText as NSString
        guard currentWordRange.location >= 0,
              currentWordRange.length > 0,
              currentWordRange.location + currentWordRange.length <= fullNSString.length else {
            return Text(trimmedPreviewText(from: viewModel.fullText))
        }

        let contextWindow = textWindow(around: currentWordRange, in: fullNSString)
        let prefixText = contextWindow.prefix
        let currentWordText = contextWindow.currentWord
        let suffixText = contextWindow.suffix
        let showsLeadingEllipsis = contextWindow.windowStart > 0
        let showsTrailingEllipsis = contextWindow.windowEnd < fullNSString.length

        return Text(showsLeadingEllipsis ? "... " : "")
            + Text(prefixText)
            + Text(currentWordText).bold().foregroundColor(DS.Colors.accent)
            + Text(suffixText)
            + Text(showsTrailingEllipsis ? " ..." : "")
    }

    /// Keep popover compact by only showing nearby context instead of the
    /// entire extracted document.
    private func textWindow(around currentWordRange: NSRange, in fullNSString: NSString) -> (
        prefix: String,
        currentWord: String,
        suffix: String,
        windowStart: Int,
        windowEnd: Int
    ) {
        let contextCharacterCount = 110
        let windowStart = max(0, currentWordRange.location - contextCharacterCount)
        let wordEnd = currentWordRange.location + currentWordRange.length
        let windowEnd = min(fullNSString.length, wordEnd + contextCharacterCount)

        let prefixLength = max(0, currentWordRange.location - windowStart)
        let suffixLength = max(0, windowEnd - wordEnd)

        let prefix = prefixLength > 0
            ? fullNSString.substring(with: NSRange(location: windowStart, length: prefixLength))
            : ""
        let currentWord = fullNSString.substring(with: currentWordRange)
        let suffix = suffixLength > 0
            ? fullNSString.substring(with: NSRange(location: wordEnd, length: suffixLength))
            : ""

        return (prefix, currentWord, suffix, windowStart, windowEnd)
    }

    private func trimmedPreviewText(from fullText: String) -> String {
        let previewLimit = 240
        if fullText.count <= previewLimit {
            return fullText
        }
        let endIndex = fullText.index(fullText.startIndex, offsetBy: previewLimit)
        return String(fullText[..<endIndex]) + " ..."
    }
}
