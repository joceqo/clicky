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

/// Supported layouts for the read-aloud popover. Selectable in Settings.
enum ReadAloudPopoverDisplayMode: String {
    /// Original compact 440×150 box showing ~110 chars of context around the
    /// current word. Fastest to scan but drops surrounding paragraphs.
    case window
    /// Sentence-group layout: shows the sentence containing the current word
    /// plus one before and one after. Reads like prose.
    case paragraph
    /// Entire extracted text in a larger scrollview; the highlighted word is
    /// auto-scrolled into view so the reader never loses position.
    case fullScroll

    init(rawID: String) {
        self = ReadAloudPopoverDisplayMode(rawValue: rawID) ?? .window
    }

    /// Panel dimensions chosen to match the visual density of the layout.
    /// Bigger for fullScroll because it needs room to breathe for long texts.
    var panelSize: CGSize {
        switch self {
        case .window: return CGSize(width: 440, height: 150)
        case .paragraph: return CGSize(width: 520, height: 210)
        case .fullScroll: return CGSize(width: 560, height: 340)
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
        resizePanelToMatchCurrentDisplayMode(panel)
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

    /// Updates the layout used to render the popover. Safe to call while the
    /// popover is visible — the hosting view re-renders and the panel is
    /// resized on the next show (or the next word update if already visible).
    func setDisplayMode(_ modeRawID: String) {
        viewModel.displayMode = ReadAloudPopoverDisplayMode(rawID: modeRawID)
        if let textPopoverPanel, textPopoverPanel.isVisible {
            resizePanelToMatchCurrentDisplayMode(textPopoverPanel)
            positionPanelNearTopCenter(textPopoverPanel)
        }
    }

    private func ensurePanel() -> NSPanel {
        if let textPopoverPanel { return textPopoverPanel }

        let initialSize = viewModel.displayMode.panelSize
        let initialFrame = NSRect(x: 0, y: 0, width: initialSize.width, height: initialSize.height)
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
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView
        textPopoverPanel = panel
        return panel
    }

    private func resizePanelToMatchCurrentDisplayMode(_ panel: NSPanel) {
        let desiredSize = viewModel.displayMode.panelSize
        let currentFrame = panel.frame
        guard currentFrame.size != desiredSize else { return }
        // Keep the top-left corner stable so a resize doesn't drift the panel.
        let newOriginY = currentFrame.maxY - desiredSize.height
        panel.setFrame(
            NSRect(x: currentFrame.origin.x, y: newOriginY, width: desiredSize.width, height: desiredSize.height),
            display: true
        )
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
    /// Which layout the popover should render in. Mutated from the manager
    /// when Settings updates the user preference.
    @Published var displayMode: ReadAloudPopoverDisplayMode = .window
}

private struct ReadAloudTextPopoverView: View {
    @ObservedObject var viewModel: ReadAloudTextPopoverViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Reading")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(DS.Colors.textTertiary)

            switch viewModel.displayMode {
            case .window:
                compactWindowLayout
            case .paragraph:
                paragraphLayout
            case .fullScroll:
                fullScrollLayout
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(
            width: viewModel.displayMode.panelSize.width,
            height: viewModel.displayMode.panelSize.height
        )
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

    // MARK: - Compact window layout (original behaviour)

    private var compactWindowLayout: some View {
        ScrollView {
            compactWindowText
                .font(.system(size: 14, weight: .regular))
                .foregroundColor(DS.Colors.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.disabled)
        }
    }

    private var compactWindowText: Text {
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

    // MARK: - Paragraph layout (sentence group around current word)

    private var paragraphLayout: some View {
        ScrollView {
            paragraphText
                .font(.system(size: 14, weight: .regular))
                .foregroundColor(DS.Colors.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.disabled)
        }
    }

    /// Splits the full text into sentence-like chunks using macOS's own
    /// sentence tokenizer, locates the sentence containing the current word,
    /// and renders a group of three: previous + current + next. Falls back to
    /// the short preview when there is no active word.
    private var paragraphText: Text {
        guard let currentWordRange = viewModel.currentWordRange else {
            return Text(trimmedPreviewText(from: viewModel.fullText))
        }

        let sentenceChunks = sentenceChunks(in: viewModel.fullText)
        guard !sentenceChunks.isEmpty else {
            return compactWindowText
        }

        let currentWordEndLocation = currentWordRange.location + currentWordRange.length
        let activeSentenceIndex = sentenceChunks.firstIndex { chunk in
            let chunkEnd = chunk.range.location + chunk.range.length
            return currentWordRange.location >= chunk.range.location && currentWordRange.location < chunkEnd
        } ?? sentenceChunks.firstIndex { chunk in
            currentWordEndLocation <= chunk.range.location + chunk.range.length
        } ?? 0

        let firstChunkIndex = max(0, activeSentenceIndex - 1)
        let lastChunkIndex = min(sentenceChunks.count - 1, activeSentenceIndex + 1)

        var composedText = Text("")
        for (indexOffset, chunkIndex) in (firstChunkIndex...lastChunkIndex).enumerated() {
            let chunk = sentenceChunks[chunkIndex]
            if indexOffset > 0 {
                composedText = composedText + Text(" ")
            }
            if chunkIndex == activeSentenceIndex {
                composedText = composedText + highlightedChunkText(chunk: chunk, currentWordRange: currentWordRange)
            } else {
                composedText = composedText + Text(chunk.text)
                    .foregroundColor(DS.Colors.textSecondary)
            }
        }
        return composedText
    }

    /// Renders a sentence chunk with the current word bolded + tinted when it
    /// falls inside this chunk. Falls back to plain rendering otherwise.
    private func highlightedChunkText(chunk: SentenceChunk, currentWordRange: NSRange) -> Text {
        let fullNSString = viewModel.fullText as NSString
        let chunkEnd = chunk.range.location + chunk.range.length
        guard currentWordRange.location >= chunk.range.location,
              currentWordRange.location + currentWordRange.length <= chunkEnd else {
            return Text(chunk.text)
        }

        let beforeLength = currentWordRange.location - chunk.range.location
        let afterLocation = currentWordRange.location + currentWordRange.length
        let afterLength = chunkEnd - afterLocation

        let beforeText = beforeLength > 0
            ? fullNSString.substring(with: NSRange(location: chunk.range.location, length: beforeLength))
            : ""
        let wordText = fullNSString.substring(with: currentWordRange)
        let afterText = afterLength > 0
            ? fullNSString.substring(with: NSRange(location: afterLocation, length: afterLength))
            : ""

        return Text(beforeText)
            + Text(wordText).bold().foregroundColor(DS.Colors.accent)
            + Text(afterText)
    }

    private struct SentenceChunk {
        let text: String
        let range: NSRange
    }

    private func sentenceChunks(in fullText: String) -> [SentenceChunk] {
        var chunks: [SentenceChunk] = []
        let nsString = fullText as NSString
        fullText.enumerateSubstrings(in: fullText.startIndex..., options: .bySentences) {
            substring, substringRange, _, _ in
            guard let substring = substring else { return }
            let nsRange = NSRange(substringRange, in: fullText)
            guard nsRange.location >= 0,
                  nsRange.location + nsRange.length <= nsString.length else { return }
            chunks.append(SentenceChunk(text: substring, range: nsRange))
        }
        return chunks
    }

    // MARK: - Full scroll layout (entire text, auto-scroll to highlight)

    /// Renders the entire text broken into sentence chunks so each one can
    /// carry its own id, and the ScrollViewReader can jump to the sentence
    /// containing the current word as playback advances. Inactive sentences
    /// stay muted so the reader's eye is drawn to the active one.
    private var fullScrollLayout: some View {
        let sentenceChunks = sentenceChunks(in: viewModel.fullText)
        let activeSentenceIndex = activeSentenceIndex(in: sentenceChunks)

        return ScrollViewReader { scrollProxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(sentenceChunks.enumerated()), id: \.offset) { sentenceIndexAndChunk in
                        let sentenceIndex = sentenceIndexAndChunk.offset
                        let sentenceChunk = sentenceIndexAndChunk.element
                        sentenceRenderedText(
                            chunk: sentenceChunk,
                            isActive: sentenceIndex == activeSentenceIndex
                        )
                        .font(.system(size: 14, weight: .regular))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.disabled)
                        .id(sentenceIndex)
                    }
                }
            }
            .onChange(of: activeSentenceIndex) { newActiveSentenceIndex in
                guard let newActiveSentenceIndex else { return }
                withAnimation(.easeOut(duration: 0.18)) {
                    scrollProxy.scrollTo(newActiveSentenceIndex, anchor: .center)
                }
            }
        }
    }

    /// Renders a single sentence. Active sentence uses primary text + bold
    /// accent word highlight; inactive sentences are rendered muted so they
    /// act as visible-but-secondary context on either side.
    private func sentenceRenderedText(chunk: SentenceChunk, isActive: Bool) -> Text {
        if isActive, let currentWordRange = viewModel.currentWordRange {
            return highlightedChunkText(chunk: chunk, currentWordRange: currentWordRange)
                .foregroundColor(DS.Colors.textPrimary)
        }
        return Text(chunk.text)
            .foregroundColor(isActive ? DS.Colors.textPrimary : DS.Colors.textSecondary)
    }

    /// Finds the sentence index containing the current word, or the first
    /// sentence whose range starts at/after the word if no exact match.
    private func activeSentenceIndex(in sentenceChunks: [SentenceChunk]) -> Int? {
        guard !sentenceChunks.isEmpty else { return nil }
        guard let currentWordRange = viewModel.currentWordRange else { return nil }
        let currentWordEndLocation = currentWordRange.location + currentWordRange.length
        if let exactMatch = sentenceChunks.firstIndex(where: { chunk in
            let chunkEnd = chunk.range.location + chunk.range.length
            return currentWordRange.location >= chunk.range.location && currentWordRange.location < chunkEnd
        }) {
            return exactMatch
        }
        return sentenceChunks.firstIndex { chunk in
            currentWordEndLocation <= chunk.range.location + chunk.range.length
        }
    }

    // MARK: - Shared

    private func trimmedPreviewText(from fullText: String) -> String {
        let previewLimit = 240
        if fullText.count <= previewLimit {
            return fullText
        }
        let endIndex = fullText.index(fullText.startIndex, offsetBy: previewLimit)
        return String(fullText[..<endIndex]) + " ..."
    }
}
