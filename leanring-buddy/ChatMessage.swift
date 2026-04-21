//
//  ChatMessage.swift
//  leanring-buddy
//
//  Model for a single message in the Clicky chat window.
//  Both voice (push-to-talk) and text (typed) exchanges share this model
//  so the chat window displays the full conversation history regardless of
//  how the user interacted with Clicky.
//
//  Codable so ConversationStore can persist the message list to JSON.
//

import CoreGraphics
import Foundation

/// Whether a chat message was authored by the user or Clicky.
enum ChatMessageRole: String, Codable {
    case user
    case assistant
}

/// How the message originated — pushed via voice, typed in the chat window,
/// or captured by the ⌃⇧L read-aloud shortcut.
/// Used by the chat UI to badge messages appropriately.
enum ChatMessageSource: String, Codable {
    case voice
    case text
    case readAloud
}

/// A single word's captured timing inside a read-aloud recording. Persists
/// what was sent to the highlight overlay so a later Replay can reproduce
/// the animation frame-for-frame. Screen bounds are stored in AppKit screen
/// coords (bottom-left origin) the way `ExtractedWordInfo` delivers them.
struct ReadAloudWordTiming: Codable, Sendable {
    let text: String
    let startSeconds: Double
    let endSeconds: Double
    let screenBoundsX: CGFloat
    let screenBoundsY: CGFloat
    let screenBoundsWidth: CGFloat
    let screenBoundsHeight: CGFloat

    var screenBounds: CGRect {
        CGRect(x: screenBoundsX, y: screenBoundsY, width: screenBoundsWidth, height: screenBoundsHeight)
    }

    init(text: String, startSeconds: Double, endSeconds: Double, screenBounds: CGRect) {
        self.text = text
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.screenBoundsX = screenBounds.origin.x
        self.screenBoundsY = screenBounds.origin.y
        self.screenBoundsWidth = screenBounds.size.width
        self.screenBoundsHeight = screenBounds.size.height
    }
}

/// Screen frame of a single captured screenshot at capture time. Stored so
/// the replay popover can map a word's screen-coord bounding box into image
/// pixel coordinates on that screenshot.
struct ReadAloudScreenshotFrame: Codable, Sendable {
    let screenshotFileName: String
    let frameOriginX: CGFloat
    let frameOriginY: CGFloat
    let frameWidth: CGFloat
    let frameHeight: CGFloat

    var frame: CGRect {
        CGRect(x: frameOriginX, y: frameOriginY, width: frameWidth, height: frameHeight)
    }

    init(screenshotFileName: String, frame: CGRect) {
        self.screenshotFileName = screenshotFileName
        self.frameOriginX = frame.origin.x
        self.frameOriginY = frame.origin.y
        self.frameWidth = frame.size.width
        self.frameHeight = frame.size.height
    }
}

/// All data attached to a `source == .readAloud` message: the WAV file name
/// of the captured Kokoro audio, and per-word timings so a Replay can
/// re-drive the highlight overlay.
struct ReadAloudCaptureData: Codable, Sendable {
    /// File name (not full path) of the WAV inside the readaloud storage dir.
    let audioWavFileName: String
    /// Seconds of audio captured. Convenience so the UI doesn't have to open
    /// the WAV to show duration.
    let audioDurationSeconds: Double
    /// Per-word timings captured during playback, ordered by startSeconds.
    let wordTimings: [ReadAloudWordTiming]
    /// Per-screenshot display frame at capture time, so the replay popover
    /// can map word screen bounds into image-local coords. Empty for legacy
    /// captures taken before this field was added (graceful degradation).
    var screenshotFrames: [ReadAloudScreenshotFrame] = []
}

/// A single message in the Clicky chat window.
///
/// `content` is `var` because assistant messages are updated in-place during
/// streaming — each SSE chunk overwrites the accumulated text rather than
/// creating a new message.
///
/// `screenshotFileNames` is `var` because screenshots are compressed and saved
/// to disk asynchronously after the message is appended to the list. The field
/// starts empty and is filled in once the background save finishes.
struct ChatMessage: Identifiable, Codable {
    let id: UUID
    let role: ChatMessageRole
    var content: String
    let timestamp: Date
    /// `var` because a `.readAloud` placeholder can be demoted to `.text` when
    /// the user stops playback before audio capture completes — the text is
    /// still worth keeping in the conversation even without a replay-able
    /// recording, and `.text` makes the chat UI render it as a plain message
    /// instead of the "Capturing audio…" card stuck on an empty capture.
    var source: ChatMessageSource
    /// The model that generated this response (e.g. "claude-sonnet-4-6", "lmstudio").
    /// `nil` for user messages. Stored so the chat UI can show which model answered
    /// and the conversation JSON serves as a complete debug log.
    let modelID: String?
    /// Screen text extracted via OCR/Accessibility at the time of the voice query.
    /// `nil` for text-chat messages and for Claude-mode voice messages where OCR
    /// is not run (Claude sees the actual screenshot instead).
    let ocrText: String?
    /// File names of compressed screenshots saved to disk for this message.
    /// Empty for text-chat messages and populated asynchronously for voice messages.
    /// Files live in `~/Library/Application Support/Clicky/screenshots/`.
    var screenshotFileNames: [String]
    /// Bundle identifier of the frontmost app when the screenshot was taken.
    /// Used to display the app icon alongside screenshot thumbnails in the chat.
    let foregroundAppBundleID: String?
    /// Display name of the frontmost app when the screenshot was taken.
    let foregroundAppName: String?
    /// How long the model took to generate this response, in seconds.
    /// `nil` for user messages and while still streaming. Set once streaming completes.
    var responseDurationSeconds: Double?
    /// Captured audio + word timings for `source == .readAloud` messages.
    /// `nil` for all other message types. Populated after Kokoro synthesis
    /// finishes; until then the message card shows a "captured…" placeholder.
    var readAloudCapture: ReadAloudCaptureData?

    /// Standard init — generates a new UUID automatically.
    init(
        role: ChatMessageRole,
        content: String,
        source: ChatMessageSource,
        modelID: String? = nil,
        ocrText: String? = nil,
        screenshotFileNames: [String] = [],
        foregroundAppBundleID: String? = nil,
        foregroundAppName: String? = nil,
        responseDurationSeconds: Double? = nil,
        readAloudCapture: ReadAloudCaptureData? = nil
    ) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.timestamp = Date()
        self.source = source
        self.modelID = modelID
        self.ocrText = ocrText
        self.screenshotFileNames = screenshotFileNames
        self.foregroundAppBundleID = foregroundAppBundleID
        self.foregroundAppName = foregroundAppName
        self.responseDurationSeconds = responseDurationSeconds
        self.readAloudCapture = readAloudCapture
    }

    /// Init with an explicit UUID — used when the ID must be known before
    /// the struct is created (e.g. to name screenshot files after the message
    /// before appending it to the list).
    init(
        id: UUID,
        role: ChatMessageRole,
        content: String,
        source: ChatMessageSource,
        modelID: String? = nil,
        ocrText: String? = nil,
        screenshotFileNames: [String] = [],
        foregroundAppBundleID: String? = nil,
        foregroundAppName: String? = nil,
        responseDurationSeconds: Double? = nil,
        readAloudCapture: ReadAloudCaptureData? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = Date()
        self.source = source
        self.modelID = modelID
        self.ocrText = ocrText
        self.screenshotFileNames = screenshotFileNames
        self.foregroundAppBundleID = foregroundAppBundleID
        self.foregroundAppName = foregroundAppName
        self.responseDurationSeconds = responseDurationSeconds
        self.readAloudCapture = readAloudCapture
    }
}
