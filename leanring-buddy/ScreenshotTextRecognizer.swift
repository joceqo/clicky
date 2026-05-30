//
//  ScreenshotTextRecognizer.swift
//  leanring-buddy
//
//  Shared on-device OCR helper: runs Apple's Vision text recognition over a
//  screenshot and returns the visible text. Used as a graceful fallback when a
//  brain model can't accept image attachments (e.g. text-only OpenCode models),
//  so the agent still gets the screen's text instead of failing outright.
//
//  (AppleOCRBrainAdapter has an equivalent Vision pass for its fully on-device
//  brain; this standalone utility is the reusable version for the fallback path.)
//

import Foundation
import ImageIO
import Vision

enum ScreenshotTextRecognizer {

    /// Runs Vision text recognition on image data. Nonisolated so it can run off the
    /// main actor. Returns recognized lines joined by newlines (empty on failure).
    nonisolated static func recognizeText(in data: Data) -> String {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return ""
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return ""
        }

        let lines = request.results?.compactMap { $0.topCandidates(1).first?.string } ?? []
        return lines.joined(separator: "\n")
    }
}
