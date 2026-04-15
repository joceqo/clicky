//
//  ScreenshotCaptionExtractor.swift
//  leanring-buddy
//
//  Extracts a short descriptive caption from a screenshot by running
//  Apple Vision OCR on the top portion of the image (where the window
//  title bar, tab bar, and toolbar typically live). Returns the most
//  prominent text line as a caption — e.g. "CompanionManager.swift —
//  Xcode" or "GitHub — Pull requests".
//
//  Runs synchronously on the calling thread (intended for background
//  dispatch). No model download required — uses the built-in Vision
//  text recognition engine.
//

import AppKit
import Vision

enum ScreenshotCaptionExtractor {

    /// Maximum number of characters in the returned caption.
    private static let maxCaptionLength = 80

    /// Fraction of the image height to scan from the top (title bar + toolbar area).
    private static let topScanFraction: CGFloat = 0.12

    /// Extracts a short caption from the top region of a screenshot.
    /// Returns `nil` if no text is found or the image can't be processed.
    static func extractCaption(from image: NSImage) -> String? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        let imageHeight = CGFloat(cgImage.height)
        let imageWidth = CGFloat(cgImage.width)

        // Crop to the top portion of the image where the title bar lives.
        // CGImage origin is top-left, so y=0 is the top.
        let cropHeight = imageHeight * topScanFraction
        let cropRect = CGRect(x: 0, y: 0, width: imageWidth, height: cropHeight)
        guard let croppedCGImage = cgImage.cropping(to: cropRect) else {
            return nil
        }

        // Run Vision text recognition on the cropped region
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false

        let handler = VNImageRequestHandler(cgImage: croppedCGImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        guard let observations = request.results, !observations.isEmpty else {
            return nil
        }

        // Collect all recognized text lines sorted by vertical position (top first)
        // and horizontal position (left first) within the cropped region.
        // VNRecognizedTextObservation bounding boxes use normalized coordinates
        // with origin at bottom-left, so higher y = closer to top of image.
        let sortedLines = observations
            .compactMap { observation -> (text: String, y: CGFloat, x: CGFloat)? in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return (text: text, y: observation.boundingBox.midY, x: observation.boundingBox.midX)
            }
            .sorted { lhs, rhs in
                // Higher y = closer to top in Vision coordinates (bottom-left origin)
                if abs(lhs.y - rhs.y) > 0.05 { return lhs.y > rhs.y }
                return lhs.x < rhs.x
            }

        guard !sortedLines.isEmpty else { return nil }

        // Build caption from the topmost lines (title bar area).
        // Take lines from the top row (within ~5% vertical tolerance of the first line)
        // and join them — this captures "filename — AppName" style title bars.
        let topY = sortedLines[0].y
        let topRowLines = sortedLines.filter { abs($0.y - topY) < 0.1 }
        let rawCaption = topRowLines.map(\.text).joined(separator: " — ")

        // Truncate to max length
        if rawCaption.count > maxCaptionLength {
            return String(rawCaption.prefix(maxCaptionLength - 1)) + "…"
        }

        return rawCaption.isEmpty ? nil : rawCaption
    }
}
