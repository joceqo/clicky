//
//  ReadAloudReplayPopover.swift
//  leanring-buddy
//
//  Popover window shown from a chat card's ▶ Replay button. Displays the
//  captured screenshot (what the user saw when they pressed ⌃⇧L) and
//  replays the captured audio while animating a highlight rectangle over
//  the image, synced to the stored per-word timings.
//
//  Unlike the live read-aloud overlay (which paints on the real screen and
//  breaks when the user has moved the window since), this popover is
//  self-contained: the highlight always lines up because the screenshot
//  and the word bounds come from the same capture session.
//
//  Coordinate conversion:
//    Word bounds are stored in AppKit screen coordinates (bottom-left origin)
//    relative to the display they came from. Each saved screenshot carries
//    that display's frame. To position the highlight on the image:
//      1. Translate word bounds to display-local AppKit coords
//      2. Flip Y so the origin matches image-local (top-left) coords
//      3. Scale by the rendered image size / display size
//

import AppKit
import Combine
import SwiftUI

/// Controls the NSWindow that hosts the replay popover. Kept alive by
/// `CompanionManager` so the window can be reused for subsequent replays
/// without rebuilding the SwiftUI hierarchy.
@MainActor
final class ReadAloudReplayPopoverController {
    private var popoverWindow: NSWindow?

    /// Opens (or brings to front) the replay window for the given capture
    /// and immediately starts playback. If a previous replay was showing a
    /// different message, its window is reused with the new content.
    func show(
        capture: ReadAloudCaptureData,
        fullExtractedText: String,
        conversationStore: ConversationStore,
        foregroundAppName: String?,
        highlightStyle: String = "highlight"
    ) {
        let hostingView = NSHostingView(
            rootView: ReadAloudReplayView(
                capture: capture,
                fullExtractedText: fullExtractedText,
                conversationStore: conversationStore,
                foregroundAppName: foregroundAppName,
                highlightStyle: highlightStyle,
                onCloseRequested: { [weak self] in
                    self?.close()
                }
            )
        )

        if let popoverWindow {
            popoverWindow.contentView = hostingView
            popoverWindow.makeKeyAndOrderFront(nil)
            return
        }

        let initialContentRect = NSRect(x: 0, y: 0, width: 900, height: 620)
        let newWindow = NSWindow(
            contentRect: initialContentRect,
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        newWindow.title = "Read Aloud Replay"
        newWindow.titlebarAppearsTransparent = true
        newWindow.isMovableByWindowBackground = true
        newWindow.contentView = hostingView
        newWindow.center()
        newWindow.isReleasedWhenClosed = false
        popoverWindow = newWindow
        newWindow.makeKeyAndOrderFront(nil)
    }

    func close() {
        popoverWindow?.orderOut(nil)
    }
}

// MARK: - SwiftUI view

private struct ReadAloudReplayView: View {
    let capture: ReadAloudCaptureData
    let fullExtractedText: String
    let conversationStore: ConversationStore
    let foregroundAppName: String?
    /// `"highlight"` or `"underline"` — mirrors the user's Settings pref.
    let highlightStyle: String
    let onCloseRequested: () -> Void

    @StateObject private var viewModel = ReadAloudReplayViewModel()

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            screenshotArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            controlsBar
        }
        .background(DS.Colors.background)
        .onAppear {
            viewModel.start(capture: capture, conversationStore: conversationStore)
        }
        .onDisappear {
            viewModel.stop()
        }
    }

    private var headerBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)
            Text("Read Aloud Replay")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
            if let foregroundAppName {
                Text("— \(foregroundAppName)")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textTertiary)
                    .lineLimit(1)
            }
            Spacer()
            transportControls
            Text(capture.wordTimings.count > 0 ? "\(capture.wordTimings.count) words" : "—")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(DS.Colors.surface1)
        .overlay(
            Rectangle()
                .fill(DS.Colors.borderSubtle)
                .frame(height: 1),
            alignment: .bottom
        )
    }

    /// Three icon buttons — Play/Pause, Stop, and an explicit Restart —
    /// grouped in the top bar so the user can control playback without
    /// hunting to the bottom of the window.
    private var transportControls: some View {
        HStack(spacing: 4) {
            transportButton(
                systemImage: playPauseIconName,
                help: playPauseHelp,
                action: { viewModel.togglePlayOrPause(capture: capture) }
            )
            transportButton(
                systemImage: "stop.fill",
                help: "Stop",
                action: { viewModel.stop() }
            )
            transportButton(
                systemImage: "gobackward",
                help: "Restart from beginning",
                action: { viewModel.restart(capture: capture) }
            )
        }
    }

    private var playPauseIconName: String {
        if viewModel.isPaused { return "play.fill" }
        return viewModel.isPlaying ? "pause.fill" : "play.fill"
    }

    private var playPauseHelp: String {
        if viewModel.isPaused { return "Resume" }
        return viewModel.isPlaying ? "Pause" : "Play"
    }

    private func transportButton(
        systemImage: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(DS.Colors.textPrimary)
                .frame(width: 24, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering in
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }

    private var screenshotArea: some View {
        GeometryReader { geometryProxy in
            ZStack {
                if let image = viewModel.screenshotImage,
                   let screenshotFrame = viewModel.activeScreenshotFrame {
                    // SwiftUI's aspect-ratio scaledToFit gives us the visible
                    // image rect inside geometry, which we need to position
                    // the highlight correctly.
                    let renderedRect = renderedImageRect(
                        imageSize: image.size,
                        containerSize: geometryProxy.size
                    )
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if let currentWord = viewModel.currentWordTiming,
                       let highlightRect = highlightRectOnImage(
                           for: currentWord,
                           screenshotDisplayFrame: screenshotFrame.frame,
                           renderedImageRect: renderedRect
                       ) {
                        highlightOverlay(rect: highlightRect)
                            .animation(.easeOut(duration: 0.08), value: currentWord.startSeconds)
                    }
                } else {
                    Color.black
                        .overlay(
                            VStack(spacing: 8) {
                                Image(systemName: "photo")
                                    .font(.system(size: 28, weight: .light))
                                    .foregroundColor(DS.Colors.textTertiary)
                                Text("Screenshot unavailable")
                                    .font(.system(size: 12))
                                    .foregroundColor(DS.Colors.textTertiary)
                            }
                        )
                }
            }
            .frame(width: geometryProxy.size.width, height: geometryProxy.size.height)
        }
        .padding(12)
    }

    /// Yellow highlight rendered on top of the screenshot. Swaps between a
    /// filled rectangle and a bottom-edge underline based on the user's
    /// Settings pref so the popover matches the live overlay.
    @ViewBuilder
    private func highlightOverlay(rect: CGRect) -> some View {
        if highlightStyle == "underline" {
            Rectangle()
                .fill(Color.yellow.opacity(0.9))
                .frame(width: rect.width, height: 2)
                .shadow(color: Color.yellow.opacity(0.6), radius: 2, x: 0, y: 0)
                .position(x: rect.midX, y: rect.maxY + 1)
        } else {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.yellow.opacity(0.32))
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(Color.yellow.opacity(0.65), lineWidth: 1.2)
                )
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
        }
    }

    /// Computes the CGRect that `Image.scaledToFit` actually occupies inside
    /// the given container. Needed because SwiftUI doesn't expose this rect
    /// directly and the highlight has to be positioned in container coords.
    private func renderedImageRect(imageSize: CGSize, containerSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGRect(origin: .zero, size: containerSize)
        }
        let imageAspect = imageSize.width / imageSize.height
        let containerAspect = containerSize.width / containerSize.height
        if imageAspect > containerAspect {
            // Image is wider — letterboxed top/bottom
            let renderedWidth = containerSize.width
            let renderedHeight = containerSize.width / imageAspect
            let originY = (containerSize.height - renderedHeight) / 2
            return CGRect(x: 0, y: originY, width: renderedWidth, height: renderedHeight)
        } else {
            // Image is taller — letterboxed left/right
            let renderedHeight = containerSize.height
            let renderedWidth = containerSize.height * imageAspect
            let originX = (containerSize.width - renderedWidth) / 2
            return CGRect(x: originX, y: 0, width: renderedWidth, height: renderedHeight)
        }
    }

    /// Maps a word's AppKit screen bounds to a rectangle inside the
    /// rendered image on screen. Returns nil when the word fell outside the
    /// screenshot's display (multi-monitor capture, we only show one).
    private func highlightRectOnImage(
        for wordTiming: ReadAloudWordTiming,
        screenshotDisplayFrame: CGRect,
        renderedImageRect: CGRect
    ) -> CGRect? {
        let wordBounds = wordTiming.screenBounds
        guard wordBounds != .zero else { return nil }

        // Must be on the display this screenshot represents — skip words
        // that belong to a different monitor we didn't render.
        guard screenshotDisplayFrame.intersects(wordBounds) else { return nil }

        // Local display coords (AppKit, bottom-left origin)
        let localX = wordBounds.origin.x - screenshotDisplayFrame.origin.x
        let localYBottomLeft = wordBounds.origin.y - screenshotDisplayFrame.origin.y

        // Flip Y so it matches image-local (top-left origin) coords
        let localYTopLeft = screenshotDisplayFrame.height - localYBottomLeft - wordBounds.height

        // Scale into the rendered image's on-screen size
        let scaleX = renderedImageRect.width / screenshotDisplayFrame.width
        let scaleY = renderedImageRect.height / screenshotDisplayFrame.height

        let renderedX = renderedImageRect.origin.x + localX * scaleX
        let renderedY = renderedImageRect.origin.y + localYTopLeft * scaleY
        let renderedWidth = wordBounds.width * scaleX
        let renderedHeight = wordBounds.height * scaleY

        return CGRect(x: renderedX, y: renderedY, width: renderedWidth, height: renderedHeight)
    }

    /// Bottom status bar: just the current word and total duration now —
    /// transport controls moved to the top bar header so they're always
    /// visible alongside the window title.
    private var controlsBar: some View {
        HStack(spacing: 14) {
            statusDot
            Text(viewModel.currentWordTiming?.text ?? "—")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)
                .frame(minWidth: 120, alignment: .leading)
            Spacer()
            Text(formattedDuration(capture.audioDurationSeconds))
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(DS.Colors.surface1)
    }

    /// Small colored dot reflecting playback state at a glance —
    /// green = playing, yellow = paused, gray = stopped.
    private var statusDot: some View {
        Circle()
            .fill(statusDotColor)
            .frame(width: 8, height: 8)
    }

    private var statusDotColor: Color {
        if viewModel.isPaused { return .yellow }
        if viewModel.isPlaying { return .green }
        return DS.Colors.textTertiary
    }

    private func formattedDuration(_ seconds: Double) -> String {
        if seconds < 60 {
            return String(format: "%.1fs", seconds)
        }
        let minutes = Int(seconds / 60)
        let remainderSeconds = Int(seconds.truncatingRemainder(dividingBy: 60))
        return String(format: "%dm %ds", minutes, remainderSeconds)
    }
}

// MARK: - View model

@MainActor
private final class ReadAloudReplayViewModel: ObservableObject {
    @Published var screenshotImage: NSImage?
    @Published var activeScreenshotFrame: ReadAloudScreenshotFrame?
    @Published var currentWordTiming: ReadAloudWordTiming?
    @Published var isPlaying: Bool = false
    @Published var isPaused: Bool = false

    private let replayController = ReadAloudReplayController()

    /// Loads the screenshot + starts audio playback automatically when the
    /// popover first appears. Picks the primary (first) screenshot since
    /// that's the display the cursor was on at capture time.
    func start(capture: ReadAloudCaptureData, conversationStore: ConversationStore) {
        loadScreenshot(capture: capture, conversationStore: conversationStore)
        startPlayback(capture: capture)
    }

    /// Full stop — audio + highlight cleared. Used by the top-bar ⏹ button
    /// and on window dismiss.
    func stop() {
        replayController.stop()
        isPlaying = false
        isPaused = false
        currentWordTiming = nil
    }

    /// Top-bar play/pause button handler. Three cases:
    ///   - Not playing → start from the beginning
    ///   - Playing and unpaused → pause (audio + highlight freeze)
    ///   - Playing but paused → resume from the paused position
    func togglePlayOrPause(capture: ReadAloudCaptureData) {
        if !isPlaying {
            startPlayback(capture: capture)
            return
        }
        if isPaused {
            replayController.resume()
            isPaused = false
        } else {
            replayController.pause()
            isPaused = true
        }
    }

    /// Stops any in-progress playback then restarts from time zero.
    func restart(capture: ReadAloudCaptureData) {
        replayController.stop()
        currentWordTiming = nil
        startPlayback(capture: capture)
    }

    /// Kicks off a fresh playback session. Separate helper so `start`,
    /// `togglePlayOrPause`, and `restart` share the same error handling +
    /// word-timing bridging without duplication.
    private func startPlayback(capture: ReadAloudCaptureData) {
        do {
            try replayController.play(
                wavFileName: capture.audioWavFileName,
                wordTimings: capture.wordTimings
            ) { [weak self] wordTiming in
                guard let self else { return }
                self.currentWordTiming = wordTiming
                if wordTiming == nil {
                    self.isPlaying = false
                    self.isPaused = false
                }
            }
            isPlaying = true
            isPaused = false
        } catch {
            print("⚠️ Read-aloud replay error: \(error)")
            isPlaying = false
            isPaused = false
        }
    }

    private func loadScreenshot(capture: ReadAloudCaptureData, conversationStore: ConversationStore) {
        guard let screenshotFrame = capture.screenshotFrames.first else {
            activeScreenshotFrame = nil
            return
        }
        activeScreenshotFrame = screenshotFrame
        let screenshotFileURL = conversationStore.screenshotFileURL(fileName: screenshotFrame.screenshotFileName)
        Task.detached(priority: .utility) { [weak self] in
            let image = NSImage(contentsOf: screenshotFileURL)
            await MainActor.run {
                self?.screenshotImage = image
            }
        }
    }
}
