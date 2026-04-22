//
//  TextExtractor.swift
//  leanring-buddy
//
//  Extracts visible text from the currently focused app, using two strategies:
//
//  Strategy A — Accessibility API (AX): Reads text directly from the focused UI
//  element's AX tree. Fast and accurate for native apps (Safari, Xcode, Notes, etc.)
//  that expose their content via AXUIElement. Falls back to OCR when AX gives zero
//  bounding boxes (common with Chrome/Electron where AX text is available but
//  positions are not meaningful).
//
//  Strategy B — Vision OCR: When AX returns no usable bounds, captures the
//  frontmost window via ScreenCaptureKit and runs Apple's VNRecognizeTextRequest
//  to extract text from pixels. Works for any app regardless of AX support.
//
//  Ported from joceqo/lector (Sources/Lector/TextExtractor.swift).
//

import ApplicationServices
import AppKit
import ScreenCaptureKit
import Vision

// MARK: - Data Types

struct ExtractedWordInfo: Sendable {
    let text: String
    let range: NSRange         // character position within the full extracted text
    let screenBounds: CGRect   // bounding box in screen coords (AppKit: bottom-left origin)
}

struct ScreenTextExtractionResult: Sendable {
    let fullText: String
    let words: [ExtractedWordInfo]
    let source: ScreenTextExtractionSource
}

enum ScreenTextExtractionSource: Sendable {
    case accessibility
    case ocr
}

// MARK: - TextExtractor

final class TextExtractor {

    // MARK: - Public API

    func extract() async throws -> ScreenTextExtractionResult {
        try await extract(underCursor: nil)
    }

    /// Variant that biases the OCR fallback toward the real window under the
    /// cursor — rejects Clicky's own windows, invisible windows, and
    /// screen-wide helper/tracker overlays that park themselves at high
    /// window layers. Callers with a known cursor point (e.g. ⌃⇧L read-aloud
    /// trigger) should pass it so the picker can lock onto the window the
    /// user is actually looking at, not just the frontmost PID's first
    /// window.
    func extract(underCursor cursorPoint: CGPoint?) async throws -> ScreenTextExtractionResult {
        try await extract(underCursor: cursorPoint, skipAccessibility: false)
    }

    /// AX-skippable variant so callers with a per-app heuristics cache
    /// (e.g. `AppExtractionHeuristicsStore`) can jump straight to OCR for
    /// apps known to return nothing useful from the Accessibility tree
    /// (Chrome, Electron, VS Code, etc.). Saves the ~50–200ms AX walk cost
    /// on every trigger for those apps.
    func extract(
        underCursor cursorPoint: CGPoint?,
        skipAccessibility: Bool
    ) async throws -> ScreenTextExtractionResult {
        if !skipAccessibility {
            if let axResult = try? extractViaAccessibility(), !axResult.words.isEmpty {
                // If every word has a zero bounding box, AX didn't give us real screen
                // positions (common in Chrome and Electron). Fall back to OCR so we at
                // least have the text even if coords are approximate.
                let hasRealBounds = axResult.words.contains { $0.screenBounds != .zero }
                if hasRealBounds {
                    return axResult
                }
            }
        }
        return try await extractViaOCR(underCursor: cursorPoint)
    }

    // MARK: - Strategy A: Accessibility API

    private func extractViaAccessibility() throws -> ScreenTextExtractionResult {
        let systemWide = AXUIElementCreateSystemWide()

        // Get the focused UI element from whichever app is frontmost
        guard let focusedRaw = axValue(systemWide, kAXFocusedUIElementAttribute) else {
            throw TextExtractionError.noFocusedElement
        }
        let focusedElement = focusedRaw as! AXUIElement

        // Walk the AX tree to find the best text-bearing element
        guard let textBearingElement = findTextBearingElement(from: focusedElement) else {
            throw TextExtractionError.noTextFound
        }

        // Pull the full text string out of the element
        guard let fullText = readTextFromElement(textBearingElement), !fullText.isEmpty else {
            throw TextExtractionError.noTextFound
        }

        let words = buildWordBoundsFromElement(textBearingElement, fullText: fullText)
        return ScreenTextExtractionResult(fullText: fullText, words: words, source: .accessibility)
    }

    /// Walk up/down the AX tree starting from the focused element to find an element
    /// that has readable text content.
    private func findTextBearingElement(from element: AXUIElement) -> AXUIElement? {
        let textRoles: Set<String> = [
            kAXTextAreaRole, kAXTextFieldRole, kAXStaticTextRole,
            "AXWebArea", kAXGroupRole
        ]

        // Check if the focused element itself carries text
        if let role = axValue(element, kAXRoleAttribute) as? String,
           textRoles.contains(role),
           readTextFromElement(element) != nil {
            return element
        }

        // Search the element's children
        if let childWithText = searchChildrenForText(of: element) {
            return childWithText
        }

        // Try the parent's children (siblings of the focused element)
        if let parentRef = axValue(element, kAXParentAttribute) {
            let parentElement = parentRef as! AXUIElement
            if let childWithText = searchChildrenForText(of: parentElement) {
                return childWithText
            }
        }

        return nil
    }

    /// Recursively search children of an AX element for one that has text content.
    /// Limits recursion to 3 levels to avoid traversing huge trees.
    private func searchChildrenForText(of element: AXUIElement, depth: Int = 0) -> AXUIElement? {
        guard depth < 3 else { return nil }
        guard let children = axValue(element, kAXChildrenAttribute) as? [AXUIElement] else {
            return nil
        }

        let textRoles: Set<String> = [
            kAXTextAreaRole, kAXTextFieldRole, kAXStaticTextRole
        ]

        for child in children {
            if let role = axValue(child, kAXRoleAttribute) as? String,
               textRoles.contains(role),
               readTextFromElement(child) != nil {
                return child
            }
        }

        // No direct match — recurse deeper
        for child in children {
            if let found = searchChildrenForText(of: child, depth: depth + 1) {
                return found
            }
        }

        return nil
    }

    /// Read text from an AX element by trying kAXValueAttribute, kAXTitleAttribute,
    /// and finally concatenating the text of all child elements.
    private func readTextFromElement(_ element: AXUIElement) -> String? {
        if let value = axValue(element, kAXValueAttribute) as? String, !value.isEmpty {
            return value
        }
        if let title = axValue(element, kAXTitleAttribute) as? String, !title.isEmpty {
            return title
        }
        return concatenateChildrenText(of: element)
    }

    private func concatenateChildrenText(of element: AXUIElement) -> String? {
        guard let children = axValue(element, kAXChildrenAttribute) as? [AXUIElement] else {
            return nil
        }
        var parts: [String] = []
        for child in children {
            if let text = axValue(child, kAXValueAttribute) as? String, !text.isEmpty {
                parts.append(text)
            } else if let text = axValue(child, kAXTitleAttribute) as? String, !text.isEmpty {
                parts.append(text)
            }
        }
        let combinedText = parts.joined(separator: " ")
        return combinedText.isEmpty ? nil : combinedText
    }

    /// Build a list of words with their screen bounding boxes using
    /// kAXBoundsForRangeParameterizedAttribute. Falls back to per-child block bounds
    /// when the parameterized attribute isn't supported.
    private func buildWordBoundsFromElement(_ element: AXUIElement, fullText: String) -> [ExtractedWordInfo] {
        let nsText = fullText as NSString
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0

        if let words = buildWordBoundsViaParameterizedAttribute(
            element: element,
            fullText: fullText,
            nsText: nsText,
            screenHeight: screenHeight
        ) {
            return words
        }

        // Parameterized attribute not supported — fall back to child block bounds
        return buildWordBoundsFromChildElements(element: element, fullText: fullText)
    }

    /// Use kAXBoundsForRangeParameterizedAttribute to get a per-word CGRect for
    /// each word in fullText. Returns nil if the attribute isn't supported.
    private func buildWordBoundsViaParameterizedAttribute(
        element: AXUIElement,
        fullText: String,
        nsText: NSString,
        screenHeight: CGFloat
    ) -> [ExtractedWordInfo]? {
        var resultWords: [ExtractedWordInfo] = []
        var atLeastOneWordHasBounds = false

        fullText.enumerateSubstrings(in: fullText.startIndex..., options: .byWords) {
            [self] wordString, substringRange, _, _ in
            guard let wordString = wordString else { return }

            let nsRange = NSRange(substringRange, in: fullText)
            var cfRange = CFRange(location: nsRange.location, length: nsRange.length)

            guard let rangeValue = AXValueCreate(.cfRange, &cfRange) else { return }

            if let boundsRef = self.axParameterizedValue(
                element,
                kAXBoundsForRangeParameterizedAttribute,
                rangeValue
            ) {
                var wordRect = CGRect.zero
                if AXValueGetValue(boundsRef as! AXValue, .cgRect, &wordRect) {
                    // AX returns coordinates with top-left origin (CoreGraphics convention).
                    // Convert to AppKit convention (bottom-left origin) for consistency
                    // with the rest of the overlay coordinate system.
                    wordRect.origin.y = screenHeight - wordRect.origin.y - wordRect.height

                    resultWords.append(ExtractedWordInfo(
                        text: wordString,
                        range: nsRange,
                        screenBounds: wordRect
                    ))
                    atLeastOneWordHasBounds = true
                }
            }
        }

        return atLeastOneWordHasBounds ? resultWords : nil
    }

    /// Fallback word-bounds strategy: enumerate AXStaticText children and use
    /// each child's overall position/size as the bounding box for all words in it.
    private func buildWordBoundsFromChildElements(element: AXUIElement, fullText: String) -> [ExtractedWordInfo] {
        guard let children = axValue(element, kAXChildrenAttribute) as? [AXUIElement] else {
            return makeWordsWithZeroBounds(fullText: fullText)
        }

        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        var resultWords: [ExtractedWordInfo] = []
        var characterOffset = 0

        for child in children {
            guard let role = axValue(child, kAXRoleAttribute) as? String,
                  role == kAXStaticTextRole,
                  let childText = axValue(child, kAXValueAttribute) as? String
                                  ?? axValue(child, kAXTitleAttribute) as? String,
                  !childText.isEmpty else {
                continue
            }

            // Resolve the child's screen bounds from its AX position + size
            var childScreenBounds = CGRect.zero
            if let positionRef = axValue(child, kAXPositionAttribute),
               let sizeRef = axValue(child, kAXSizeAttribute) {
                var childOrigin = CGPoint.zero
                var childSize = CGSize.zero
                AXValueGetValue(positionRef as! AXValue, .cgPoint, &childOrigin)
                AXValueGetValue(sizeRef as! AXValue, .cgSize, &childSize)
                childScreenBounds = CGRect(origin: childOrigin, size: childSize)
                // Convert CG (top-left) to AppKit (bottom-left) convention
                childScreenBounds.origin.y = screenHeight - childScreenBounds.origin.y - childScreenBounds.height
            }

            childText.enumerateSubstrings(in: childText.startIndex..., options: .byWords) {
                wordString, substringRange, _, _ in
                guard let wordString = wordString else { return }
                let localRange = NSRange(substringRange, in: childText)
                let globalRange = NSRange(location: characterOffset + localRange.location, length: localRange.length)
                resultWords.append(ExtractedWordInfo(
                    text: wordString,
                    range: globalRange,
                    screenBounds: childScreenBounds
                ))
            }

            characterOffset += childText.count + 1 // +1 for the separator space
        }

        return resultWords
    }

    /// Last-resort fallback: return words with zero bounding boxes when no positional
    /// information is available at all.
    private func makeWordsWithZeroBounds(fullText: String) -> [ExtractedWordInfo] {
        var words: [ExtractedWordInfo] = []
        fullText.enumerateSubstrings(in: fullText.startIndex..., options: .byWords) {
            wordString, substringRange, _, _ in
            guard let wordString = wordString else { return }
            let nsRange = NSRange(substringRange, in: fullText)
            words.append(ExtractedWordInfo(text: wordString, range: nsRange, screenBounds: .zero))
        }
        return words
    }

    // MARK: - Strategy B: Vision OCR

    private func extractViaOCR(underCursor cursorPoint: CGPoint?) async throws -> ScreenTextExtractionResult {
        let windowCapture = try getWindowCaptureInfo(underCursor: cursorPoint)
        print("🔎 TextExtractor: OCR target window → owner=\(windowCapture.ownerName ?? "?") pid=\(windowCapture.ownerPID) layer=\(windowCapture.layer) bounds=\(windowCapture.bounds)")
        let capturedImage = try await captureWindowImage(windowCapture: windowCapture)
        let (fullText, words) = try runVisionOCR(on: capturedImage, windowBounds: windowCapture.bounds)
        return ScreenTextExtractionResult(fullText: fullText, words: words, source: .ocr)
    }

    private struct WindowCaptureInfo {
        let bounds: CGRect        // Screen coords, AppKit convention (bottom-left origin)
        let windowID: CGWindowID
        let ownerPID: pid_t
        let ownerName: String?
        let layer: Int
    }

    /// System windows that are full-screen or near-full-screen but have no
    /// real content — picking them wastes an OCR pass and returns zero words.
    /// Ported from SwiftGrab `WindowHitTester.blockedBundleIDs` so the two
    /// projects stay in parity.
    private static let blockedWindowBundleIDs: Set<String> = [
        "com.apple.screencaptureui",   // macOS Screenshot tool overlay
        "com.apple.WindowManager",     // Stage Manager scaffolding
        "com.apple.dock",              // Dock, Mission Control host
        "com.apple.controlcenter",     // Control Center chrome
        "com.apple.notificationcenterui" // Notification Center overlay
    ]

    /// Owner-name level filter for processes whose bundle ID isn't
    /// straightforward to look up (WindowServer owns the wallpaper/menu-bar
    /// compositor windows and must never be OCR'd).
    private static let blockedWindowOwnerNames: Set<String> = ["WindowServer"]

    /// Picks the window to OCR by walking `CGWindowListCopyWindowInfo` in
    /// front-to-back order. Strategy:
    ///
    ///   1. Skip our own process — otherwise the ⌃⇧L shortcut would happily
    ///      OCR the Clicky panel the user just clicked through.
    ///   2. Skip invisible windows (alpha ≤ 0.01).
    ///   3. Skip screen-wide helper trackers — any window at layer > 150 that
    ///      covers ≥ 90% of the screen. Automation assistants, screen
    ///      recorders, and cursor-trackers park invisible full-screen windows
    ///      up there that would otherwise swallow every hit-test.
    ///   4. When a cursor point is provided, prefer the topmost window that
    ///      contains it. This picks small legitimate overlays (Clicky-style
    ///      popovers in other apps, notifications) over the app behind them,
    ///      which matches "read what I'm looking at."
    ///   5. Fallback: first window of `NSWorkspace.frontmostApplication`.
    ///
    /// Ported from SwiftGrab (`WindowHitTester.firstMatch`) — same layer +
    /// coverage thresholds so the two projects stay in parity.
    private func getWindowCaptureInfo(underCursor cursorPoint: CGPoint?) throws -> WindowCaptureInfo {
        let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[CFString: Any]] ?? []

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? 0
        let screenSize = NSScreen.main?.frame.size ?? .zero

        // Convert cursor from AppKit global (bottom-left origin) to Quartz
        // (top-left origin) so it matches kCGWindowBounds' coordinate space.
        let quartzCursorPoint: CGPoint? = cursorPoint.map { point in
            CGPoint(x: point.x, y: primaryScreenHeight - point.y)
        }

        var cursorHitCandidate: WindowCaptureInfo?
        // Instead of "first window of frontmost app" — which returns whatever
        // is topmost in Z-order and can be a tooltip/popover sub-window —
        // collect the *largest-area* window owned by the frontmost PID. For
        // the overwhelmingly common case of "cursor over the real content",
        // this is the main document window, not a transient popover.
        var largestFrontmostAppCandidate: WindowCaptureInfo?
        var largestFrontmostAppArea: CGFloat = 0
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier

        for windowDict in windowList {
            guard let ownerPID = windowDict[kCGWindowOwnerPID] as? Int32,
                  ownerPID != ownPID else {
                continue
            }
            guard let boundsDict = windowDict[kCGWindowBounds] as? [String: CGFloat],
                  let windowID = windowDict[kCGWindowNumber] as? CGWindowID else {
                continue
            }

            let alpha = (windowDict[kCGWindowAlpha] as? NSNumber)?.doubleValue ?? 1.0
            if alpha <= 0.01 { continue }

            // Reject system overlays that own full-screen windows with no
            // real content — otherwise they win the "largest-area" pick and
            // the OCR pass returns zero words (expensive no-op). Common
            // culprits: macOS Screenshot tool after ⌘⇧5, the Dock's
            // Mission-Control backdrop, Stage Manager scaffolding.
            let ownerName = windowDict[kCGWindowOwnerName] as? String
            if let ownerName, Self.blockedWindowOwnerNames.contains(ownerName) { continue }
            if let bundleID = NSRunningApplication(processIdentifier: ownerPID)?.bundleIdentifier,
               Self.blockedWindowBundleIDs.contains(bundleID) {
                continue
            }

            let windowX = boundsDict["X"] ?? 0
            let windowY = boundsDict["Y"] ?? 0
            let windowWidth = boundsDict["Width"] ?? 0
            let windowHeight = boundsDict["Height"] ?? 0
            let quartzBounds = CGRect(x: windowX, y: windowY, width: windowWidth, height: windowHeight)

            let layer = (windowDict[kCGWindowLayer] as? NSNumber)?.intValue ?? 0
            let coverage = screenSize.width > 0 && screenSize.height > 0
                ? (windowWidth * windowHeight) / (screenSize.width * screenSize.height)
                : 0
            if layer > 150 && coverage > 0.9 { continue }

            let appKitY = primaryScreenHeight - windowY - windowHeight
            let candidate = WindowCaptureInfo(
                bounds: CGRect(x: windowX, y: appKitY, width: windowWidth, height: windowHeight),
                windowID: windowID,
                ownerPID: ownerPID,
                ownerName: ownerName,
                layer: layer
            )

            if let quartzCursorPoint, cursorHitCandidate == nil,
               quartzBounds.contains(quartzCursorPoint) {
                cursorHitCandidate = candidate
            }
            if let frontmostPID, ownerPID == frontmostPID {
                let area = windowWidth * windowHeight
                if area > largestFrontmostAppArea {
                    largestFrontmostAppArea = area
                    largestFrontmostAppCandidate = candidate
                }
            }
            // If we have no cursor point to bias with and no frontmost hint,
            // fall back to the first otherwise-acceptable window (front-most
            // real window after filtering).
            if cursorPoint == nil && largestFrontmostAppCandidate == nil && frontmostPID == nil {
                return candidate
            }
        }

        // Priority:
        //   1. If the cursor-hit window is from a DIFFERENT process than the
        //      frontmost app, prefer it — that's a legitimate cross-app
        //      overlay (notification, floating helper, another app peeking
        //      through) and is what the user is actually looking at.
        //   2. Otherwise prefer the frontmost app's own first window.
        //      Same-PID hits tend to be tooltips, context menus, or small
        //      popovers that would OCR to nearly nothing; the main window
        //      has the content the user means to read.
        //   3. As a last resort, accept whatever the cursor hit (no
        //      frontmost hint available) or fail out.
        if let cursorHitCandidate,
           let largestFrontmostAppCandidate,
           cursorHitCandidate.ownerPID != largestFrontmostAppCandidate.ownerPID {
            return cursorHitCandidate
        }
        if let largestFrontmostAppCandidate { return largestFrontmostAppCandidate }
        if let cursorHitCandidate { return cursorHitCandidate }
        throw TextExtractionError.noWindowFound
    }

    /// Capture a single window via ScreenCaptureKit and return its CGImage.
    private func captureWindowImage(windowCapture: WindowCaptureInfo) async throws -> CGImage {
        let shareableContent = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )

        guard let targetWindow = shareableContent.windows.first(where: {
            $0.windowID == windowCapture.windowID
        }) else {
            throw TextExtractionError.windowNotCapturable
        }

        let contentFilter = SCContentFilter(desktopIndependentWindow: targetWindow)
        let streamConfig = SCStreamConfiguration()
        // Capture at Retina resolution for better OCR accuracy
        streamConfig.width = Int(windowCapture.bounds.width) * 2
        streamConfig.height = Int(windowCapture.bounds.height) * 2

        let capturedImage = try await SCScreenshotManager.captureImage(
            contentFilter: contentFilter,
            configuration: streamConfig
        )
        return capturedImage
    }

    /// Run Apple's Vision OCR on a captured window image and extract word-level
    /// bounding boxes mapped back to screen coordinates.
    private func runVisionOCR(
        on capturedImage: CGImage,
        windowBounds: CGRect
    ) throws -> (String, [ExtractedWordInfo]) {
        let recognitionRequest = VNRecognizeTextRequest()
        recognitionRequest.recognitionLevel = .accurate
        recognitionRequest.usesLanguageCorrection = true

        let imageRequestHandler = VNImageRequestHandler(cgImage: capturedImage)
        try imageRequestHandler.perform([recognitionRequest])

        var fullText = ""
        var resultWords: [ExtractedWordInfo] = []

        guard let observations = recognitionRequest.results else {
            return ("", [])
        }

        for textObservation in observations {
            guard let bestCandidate = textObservation.topCandidates(1).first else { continue }
            let lineText = bestCandidate.string
            // Capture the line-level bounding box now. Vision sometimes refuses to
            // give per-word boxes (short words, edge glyphs, bilingual text) but
            // always provides the line box. We fall back to a character-fraction
            // estimate within the line rather than returning .zero, which would
            // cause cursor anchoring to silently degrade to "read from top".
            let lineObservationBoundingBox = textObservation.boundingBox

            if !fullText.isEmpty { fullText += "\n" }
            let lineStartIndex = fullText.count
            fullText += lineText

            // Map each word in the line to its screen position
            lineText.enumerateSubstrings(in: lineText.startIndex..., options: .byWords) {
                wordString, substringRange, _, _ in
                guard let wordString = wordString else { return }

                let localRange = NSRange(substringRange, in: lineText)
                let globalRange = NSRange(location: lineStartIndex + localRange.location, length: localRange.length)

                // Vision returns normalized coordinates (0–1 range) with bottom-left origin,
                // which matches AppKit convention. Scale to actual screen pixels.
                if let wordBox = try? bestCandidate.boundingBox(for: substringRange) {
                    let bottomLeft = wordBox.bottomLeft
                    let topRight = wordBox.topRight

                    let screenX = windowBounds.origin.x + bottomLeft.x * windowBounds.width
                    let screenY = windowBounds.origin.y + bottomLeft.y * windowBounds.height
                    let screenWidth = (topRight.x - bottomLeft.x) * windowBounds.width
                    let screenHeight = (topRight.y - bottomLeft.y) * windowBounds.height

                    resultWords.append(ExtractedWordInfo(
                        text: wordString,
                        range: globalRange,
                        screenBounds: CGRect(x: screenX, y: screenY, width: screenWidth, height: screenHeight)
                    ))
                } else {
                    // Per-word box unavailable — estimate from the line's bounding box
                    // using the word's character fraction within the line. Character count
                    // is not pixel-accurate (variable-width fonts, ligatures) but produces
                    // a plausible x-position for anchoring. Much better than .zero, which
                    // makes sliceReadAloudTextFromCursorPoint fall back to reading from the
                    // very first word in the document (top-left symptom).
                    let estimatedBounds = self.estimateWordBoundsFromLineBoundingBox(
                        wordRange: substringRange,
                        lineText: lineText,
                        lineNormalizedBoundingBox: lineObservationBoundingBox,
                        windowBounds: windowBounds
                    )
                    resultWords.append(ExtractedWordInfo(
                        text: wordString,
                        range: globalRange,
                        screenBounds: estimatedBounds
                    ))
                }
            }
        }

        return (fullText, resultWords)
    }

    // MARK: - Strategy C: Focused cursor-region OCR

    /// Captures a region of the screen centered on `cursorPoint` and runs Vision
    /// OCR on just that crop. All returned words are within `cropSize` points of
    /// the cursor, so the caller can anchor reading trivially at (or near) the
    /// crop center without a document-wide nearest-word search.
    ///
    /// Used as a fallback in "fromCursorPoint" mode when the full-window AX/OCR
    /// extraction returns zero words with usable screen bounds — common in apps
    /// that don't support `kAXBoundsForRangeParameterizedAttribute` and whose OCR
    /// word boxes Vision can't resolve individually.
    ///
    /// - Parameters:
    ///   - cursorPoint: Cursor position in global AppKit screen coordinates (bottom-left origin).
    ///   - cropSize: Logical-point dimensions of the region to capture. Defaults to 640×320.
    /// Result of a focused cursor-crop OCR pass. Carries an extra
    /// `bottomEdgeOverflow` count so the caller can decide whether the crop
    /// clipped mid-content and a full-window OCR is needed to recover the
    /// text below the crop.
    struct CursorCropExtractionResult {
        let extraction: ScreenTextExtractionResult
        /// Number of OCR words whose bounding box touches the bottom edge
        /// of the crop rectangle. High values (> ~5) strongly suggest the
        /// crop clipped mid-paragraph and more content continues below.
        let bottomEdgeOverflow: Int
        /// Area of the crop that was OCR'd, in screen points. Used for
        /// debug logging so the tuning pass has the raw numbers.
        let cropScreenBounds: CGRect
    }

    /// Convenience for legacy callers that just want a `ScreenTextExtractionResult`.
    func extractViaOCRAroundPoint(
        _ cursorPoint: CGPoint,
        cropSize: CGSize = CGSize(width: 1400, height: 1000),
        verticalBiasBelowCursor: CGFloat = 0.75
    ) async throws -> ScreenTextExtractionResult {
        try await extractViaCursorCrop(
            cursorPoint: cursorPoint,
            cropSize: cropSize,
            verticalBiasBelowCursor: verticalBiasBelowCursor
        ).extraction
    }

    /// Captures a region around the cursor and runs Vision OCR on it.
    /// Returns the OCR result plus a `bottomEdgeOverflow` count so the
    /// caller can decide whether to fall back to a full-window OCR.
    ///
    /// Defaults (1400×1000 with 75% of vertical area below cursor) are
    /// tuned for the "read from cursor forward" case: ~10× faster than
    /// full-window OCR on a 2K display, and the below-cursor bias puts
    /// extraction effort where the reading will actually happen.
    func extractViaCursorCrop(
        cursorPoint: CGPoint,
        cropSize: CGSize = CGSize(width: 1400, height: 1000),
        verticalBiasBelowCursor: CGFloat = 0.75
    ) async throws -> CursorCropExtractionResult {
        // Fall back to the primary screen if the cursor is somehow between monitors.
        let cursorScreen = NSScreen.screens.first(where: { $0.frame.contains(cursorPoint) })
                        ?? NSScreen.screens[0]

        // Convert cursor from AppKit global → display-local CG coordinates.
        // AppKit: origin bottom-left, y increases upward.
        // Display-local CG: origin top-left of this display, y increases downward.
        let displayTopInAppKit = cursorScreen.frame.maxY
        let cursorDisplayCGX = cursorPoint.x - cursorScreen.frame.minX
        let cursorDisplayCGY = displayTopInAppKit - cursorPoint.y

        // Position the crop asymmetrically: most of the vertical area goes
        // below the cursor because cursor-anchored read-aloud reads forward
        // from the cursor position. A symmetric crop wastes OCR budget on
        // content the user has already passed.
        let paddingAboveCursor = cropSize.height * (1 - verticalBiasBelowCursor)
        let paddingBelowCursor = cropSize.height * verticalBiasBelowCursor
        let halfWidth = cropSize.width / 2
        let rawCropX = cursorDisplayCGX - halfWidth
        let rawCropY = cursorDisplayCGY - paddingAboveCursor

        // Clamp so the rect always lands fully within the display. If the
        // requested crop is larger than the display itself, shrink it so
        // the rect fits rather than anchoring at (0, 0) — matters on small
        // external monitors where the default 1400×1000 exceeds the height.
        let maxCropWidth = min(cropSize.width, cursorScreen.frame.width)
        let maxCropHeight = min(cropSize.height, cursorScreen.frame.height)
        let clampedCropX = max(0, min(rawCropX, cursorScreen.frame.width - maxCropWidth))
        let clampedCropY = max(0, min(rawCropY, cursorScreen.frame.height - maxCropHeight))
        let displayLocalSourceRect = CGRect(
            x: clampedCropX,
            y: clampedCropY,
            width: maxCropWidth,
            height: maxCropHeight
        )
        _ = paddingBelowCursor // retained for doc clarity above

        // Convert the captured crop back to AppKit global coords so runVisionOCR can
        // map Vision's normalized (0–1) coordinates to real screen positions.
        // AppKit y of the crop's bottom edge = displayTop − (CG_minY + height)
        let cropLeft = cursorScreen.frame.minX + displayLocalSourceRect.minX
        let cropBottom = displayTopInAppKit - displayLocalSourceRect.maxY
        let cropScreenBoundsAppKit = CGRect(x: cropLeft, y: cropBottom,
                                            width: displayLocalSourceRect.width,
                                            height: displayLocalSourceRect.height)

        let croppedImage = try await captureCroppedDisplayImage(
            screen: cursorScreen,
            displayLocalSourceRect: displayLocalSourceRect
        )

        let (fullText, words) = try runVisionOCR(on: croppedImage, windowBounds: cropScreenBoundsAppKit)

        // Overflow detector: count words whose bottom edge is within a few
        // points of the crop's bottom edge. These are the "clipped mid-line"
        // words that signal there's more content below the crop window.
        let bottomEdgeThresholdPoints: CGFloat = 6
        let cropBottomY = cropScreenBoundsAppKit.minY
        let bottomEdgeOverflowCount = words.filter { word in
            word.screenBounds != .zero &&
            word.screenBounds.minY - cropBottomY < bottomEdgeThresholdPoints
        }.count

        return CursorCropExtractionResult(
            extraction: ScreenTextExtractionResult(fullText: fullText, words: words, source: .ocr),
            bottomEdgeOverflow: bottomEdgeOverflowCount,
            cropScreenBounds: cropScreenBoundsAppKit
        )
    }

    /// Captures a sub-region of a display using ScreenCaptureKit.
    ///
    /// `displayLocalSourceRect` is in display-local CG coordinates: origin at the
    /// top-left of the display, y increases downward, units are logical points.
    /// This matches the coordinate space expected by `SCStreamConfiguration.sourceRect`.
    private func captureCroppedDisplayImage(
        screen: NSScreen,
        displayLocalSourceRect: CGRect
    ) async throws -> CGImage {
        // Match NSScreen to SCDisplay via CGDirectDisplayID — stable across
        // screen-arrangement changes and safe even when two displays share the
        // same logical resolution.
        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            throw TextExtractionError.noWindowFound
        }

        let shareableContent = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
        guard let targetDisplay = shareableContent.displays.first(where: { $0.displayID == displayID }) else {
            throw TextExtractionError.windowNotCapturable
        }

        let contentFilter = SCContentFilter(display: targetDisplay, excludingWindows: [])
        let streamConfig = SCStreamConfiguration()
        // sourceRect: display-local CG coordinates (top-left origin, logical points).
        // SCStreamConfiguration.sourceRect uses the same convention as display-local CG.
        streamConfig.sourceRect = displayLocalSourceRect
        // 2× resolution for better Vision OCR accuracy on Retina displays.
        streamConfig.width = Int(displayLocalSourceRect.width * 2)
        streamConfig.height = Int(displayLocalSourceRect.height * 2)

        return try await SCScreenshotManager.captureImage(
            contentFilter: contentFilter,
            configuration: streamConfig
        )
    }
    /// `boundingBox(for:)` returns nil. Divides the line's bounding box into
    /// equal-width character slots and extracts the word's slot range.
    ///
    /// Character count is not pixel-accurate (variable-width fonts, kerning,
    /// ligatures) but produces a plausible x-range for anchoring purposes.
    /// The y-position and height are taken directly from the line observation,
    /// so vertical accuracy is exact even when horizontal is approximate.
    private func estimateWordBoundsFromLineBoundingBox(
        wordRange: Range<String.Index>,
        lineText: String,
        lineNormalizedBoundingBox: CGRect,
        windowBounds: CGRect
    ) -> CGRect {
        let lineTotalCharacters = lineText.count
        guard lineTotalCharacters > 0 else { return .zero }

        let wordStartCharacterOffset = lineText.distance(from: lineText.startIndex, to: wordRange.lowerBound)
        let wordEndCharacterOffset = lineText.distance(from: lineText.startIndex, to: wordRange.upperBound)

        let startFraction = CGFloat(wordStartCharacterOffset) / CGFloat(lineTotalCharacters)
        let endFraction = CGFloat(wordEndCharacterOffset) / CGFloat(lineTotalCharacters)

        // Vision normalized coords: origin bottom-left, y increases upward.
        // lineNormalizedBoundingBox.minX/maxX are the left/right edges of the line.
        let lineNormLeft = lineNormalizedBoundingBox.minX
        let lineNormWidth = lineNormalizedBoundingBox.width

        let wordNormLeft = lineNormLeft + startFraction * lineNormWidth
        let wordNormRight = lineNormLeft + endFraction * lineNormWidth

        let screenX = windowBounds.origin.x + wordNormLeft * windowBounds.width
        let screenY = windowBounds.origin.y + lineNormalizedBoundingBox.origin.y * windowBounds.height
        let screenWidth = max(1, (wordNormRight - wordNormLeft) * windowBounds.width)
        let screenHeight = max(1, lineNormalizedBoundingBox.height * windowBounds.height)

        return CGRect(x: screenX, y: screenY, width: screenWidth, height: screenHeight)
    }

    // MARK: - AX Helpers

    private func axValue(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return error == .success ? value : nil
    }

    private func axParameterizedValue(
        _ element: AXUIElement,
        _ attribute: String,
        _ parameter: CFTypeRef
    ) -> CFTypeRef? {
        var value: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(
            element, attribute as CFString, parameter, &value
        )
        return error == .success ? value : nil
    }

    // MARK: - Errors

    enum TextExtractionError: Error {
        case noFocusedElement
        case noTextFound
        case noFrontmostApp
        case noWindowFound
        case windowNotCapturable
    }
}
