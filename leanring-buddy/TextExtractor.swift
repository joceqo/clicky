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
        // Try AX first — it's faster and doesn't require screen capture
        if let axResult = try? extractViaAccessibility(), !axResult.words.isEmpty {
            // If every word has a zero bounding box, AX didn't give us real screen
            // positions (common in Chrome and Electron). Fall back to OCR so we at
            // least have the text even if coords are approximate.
            let hasRealBounds = axResult.words.contains { $0.screenBounds != .zero }
            if hasRealBounds {
                return axResult
            }
        }
        // Fallback: capture the screen and OCR it
        return try await extractViaOCR()
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

    private func extractViaOCR() async throws -> ScreenTextExtractionResult {
        let windowCapture = try getWindowCaptureInfo()
        let capturedImage = try await captureWindowImage(windowCapture: windowCapture)
        let (fullText, words) = try runVisionOCR(on: capturedImage, windowBounds: windowCapture.bounds)
        return ScreenTextExtractionResult(fullText: fullText, words: words, source: .ocr)
    }

    private struct WindowCaptureInfo {
        let bounds: CGRect        // Screen coords, AppKit convention (bottom-left origin)
        let windowID: CGWindowID
    }

    /// Locate the frontmost application's main window using CGWindowListCopyWindowInfo.
    private func getWindowCaptureInfo() throws -> WindowCaptureInfo {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
            throw TextExtractionError.noFrontmostApp
        }

        let frontmostPID = frontmostApp.processIdentifier
        let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[CFString: Any]] ?? []

        for windowDict in windowList {
            guard let ownerPID = windowDict[kCGWindowOwnerPID] as? Int32,
                  ownerPID == frontmostPID,
                  let boundsDict = windowDict[kCGWindowBounds] as? [String: CGFloat],
                  let windowID = windowDict[kCGWindowNumber] as? CGWindowID else {
                continue
            }

            let windowX = boundsDict["X"] ?? 0
            let windowY = boundsDict["Y"] ?? 0
            let windowWidth = boundsDict["Width"] ?? 0
            let windowHeight = boundsDict["Height"] ?? 0

            // CGWindowList returns CG coordinates (top-left origin).
            // Convert to AppKit (bottom-left origin) for the overlay system.
            let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? 0
            let appKitY = primaryScreenHeight - windowY - windowHeight

            return WindowCaptureInfo(
                bounds: CGRect(x: windowX, y: appKitY, width: windowWidth, height: windowHeight),
                windowID: windowID
            )
        }

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
                    let estimatedBounds = estimateWordBoundsFromLineBoundingBox(
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

    /// Estimates a word's screen bounding box when Vision's per-word
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
