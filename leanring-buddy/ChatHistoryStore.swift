//
//  ChatHistoryStore.swift
//  leanring-buddy
//
//  Persists the Clicky chat history to disk across app launches.
//
//  Layout inside ~/Library/Application Support/Clicky/:
//    history.json          — JSON array of all ChatMessage values
//    screenshots/
//      {messageID}-screen1.jpg   — compressed screenshot for a voice message
//      {messageID}-screen2.jpg   — second monitor capture (if present)
//
//  Screenshot compression:
//    Originals from ScreenCaptureKit are full-resolution JPEGs (often 2-4 MB).
//    We resize to at most 1 280 px on the longest side and re-encode at 0.5
//    JPEG quality, which typically brings each capture down to 100–250 KB
//    while remaining sharp enough for review.
//
//  Retention policy:
//    Messages (and their screenshots) older than `maxHistoryDays` are deleted
//    automatically when history is loaded on app launch.
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

final class ChatHistoryStore {

    // MARK: - Configuration

    /// Number of days of history to keep. Messages older than this are
    /// purged on the next load.
    static let maxHistoryDays = 7

    /// Longest edge (pixels) of stored screenshots. Captures wider than this
    /// are scaled down proportionally before saving.
    static let screenshotMaxPixelDimension = 1280

    /// JPEG quality for stored screenshots. 0.5 gives a good size/quality trade-off
    /// for a historical review thumbnail; raise toward 1.0 if you need to zoom in.
    static let screenshotJPEGQuality: CGFloat = 0.5

    // MARK: - File Layout

    private let clickyAppSupportDirectoryURL: URL
    private let historyFileURL: URL
    let screenshotsDirectoryURL: URL

    init() {
        let appSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!

        clickyAppSupportDirectoryURL = appSupportURL.appendingPathComponent("Clicky")
        historyFileURL = clickyAppSupportDirectoryURL.appendingPathComponent("history.json")
        screenshotsDirectoryURL = clickyAppSupportDirectoryURL.appendingPathComponent("screenshots")

        createDirectoriesIfNeeded()
    }

    private func createDirectoriesIfNeeded() {
        try? FileManager.default.createDirectory(
            at: screenshotsDirectoryURL,
            withIntermediateDirectories: true
        )
    }

    // MARK: - Load

    /// Loads persisted messages from disk, removes entries older than
    /// `maxHistoryDays`, and cleans up any orphaned screenshot files.
    /// Returns an empty array if no history file exists yet.
    func loadHistory() -> [ChatMessage] {
        guard let jsonData = try? Data(contentsOf: historyFileURL) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard var messages = try? decoder.decode([ChatMessage].self, from: jsonData) else {
            print("⚠️ ChatHistoryStore: Failed to decode history — starting fresh")
            return []
        }

        // Purge messages older than the retention window
        let cutoffDate = Calendar.current.date(
            byAdding: .day,
            value: -Self.maxHistoryDays,
            to: Date()
        )!
        let activeMessages = messages.filter { $0.timestamp >= cutoffDate }
        let purgedCount = messages.count - activeMessages.count

        if purgedCount > 0 {
            print("🗂️ ChatHistoryStore: Purged \(purgedCount) messages older than \(Self.maxHistoryDays) days")
            messages = activeMessages
            // Delete screenshot files for the removed messages
            deleteOrphanedScreenshots(keeping: Set(messages.map { $0.id }))
            // Rewrite the cleaned history immediately
            saveHistory(messages)
        }

        print("🗂️ ChatHistoryStore: Loaded \(messages.count) messages")
        return messages
    }

    // MARK: - Save

    /// Encodes the full message list to JSON and writes it to disk.
    /// Called after each completed exchange (not on every streaming chunk).
    func saveHistory(_ messages: [ChatMessage]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted

        guard let jsonData = try? encoder.encode(messages) else {
            print("⚠️ ChatHistoryStore: Failed to encode history")
            return
        }

        do {
            try jsonData.write(to: historyFileURL, options: .atomic)
        } catch {
            print("⚠️ ChatHistoryStore: Failed to write history.json: \(error)")
        }
    }

    // MARK: - Screenshot Persistence

    /// Compresses each raw JPEG capture and saves it to the screenshots folder.
    /// Returns the list of file names saved (one per input image).
    /// Designed to run on a background thread — call via `Task.detached`.
    func saveCompressedScreenshots(
        _ rawJPEGDataItems: [Data],
        forMessageWithID messageID: UUID
    ) -> [String] {
        var savedFileNames: [String] = []

        for (screenIndex, rawData) in rawJPEGDataItems.enumerated() {
            let fileName = "\(messageID.uuidString)-screen\(screenIndex + 1).jpg"
            let fileURL = screenshotsDirectoryURL.appendingPathComponent(fileName)

            guard let compressedData = compressJPEG(rawData) else {
                print("⚠️ ChatHistoryStore: Compression failed for screen \(screenIndex + 1)")
                continue
            }

            do {
                try compressedData.write(to: fileURL, options: .atomic)
                savedFileNames.append(fileName)
                let kb = compressedData.count / 1024
                let originalKB = rawData.count / 1024
                print("🗂️ ChatHistoryStore: Saved \(fileName) (\(originalKB)KB → \(kb)KB)")
            } catch {
                print("⚠️ ChatHistoryStore: Failed to write \(fileName): \(error)")
            }
        }

        return savedFileNames
    }

    /// Returns the full URL for a screenshot file stored by this store.
    func screenshotFileURL(fileName: String) -> URL {
        return screenshotsDirectoryURL.appendingPathComponent(fileName)
    }

    // MARK: - Compression

    /// Resizes a JPEG image so its longest side is at most `screenshotMaxPixelDimension`,
    /// then re-encodes at `screenshotJPEGQuality`. Uses CoreGraphics directly to work
    /// in pixel space, bypassing NSImage's logical-unit coordinate system.
    private func compressJPEG(_ originalData: Data) -> Data? {
        guard
            let imageSource = CGImageSourceCreateWithData(originalData as CFData, nil),
            let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
        else { return nil }

        let originalWidth = cgImage.width
        let originalHeight = cgImage.height
        let maxDimension = Self.screenshotMaxPixelDimension

        // Only scale down — never upscale a small image
        let scale = min(
            CGFloat(maxDimension) / CGFloat(originalWidth),
            CGFloat(maxDimension) / CGFloat(originalHeight),
            1.0
        )

        let targetWidth  = max(1, Int(CGFloat(originalWidth)  * scale))
        let targetHeight = max(1, Int(CGFloat(originalHeight) * scale))

        // Draw the original image into a smaller CGContext
        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))

        guard let resizedCGImage = context.makeImage() else { return nil }

        // Encode the resized image as JPEG at the target quality
        let outputData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            outputData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }

        CGImageDestinationAddImage(
            destination,
            resizedCGImage,
            [kCGImageDestinationLossyCompressionQuality: Self.screenshotJPEGQuality] as CFDictionary
        )

        guard CGImageDestinationFinalize(destination) else { return nil }

        return outputData as Data
    }

    // MARK: - Cleanup

    /// Deletes screenshot files on disk whose message IDs are not in `activeIDs`.
    /// Called after history is pruned to avoid accumulating orphaned files.
    private func deleteOrphanedScreenshots(keeping activeIDs: Set<UUID>) {
        guard let fileNames = try? FileManager.default.contentsOfDirectory(
            atPath: screenshotsDirectoryURL.path
        ) else { return }

        var deletedCount = 0
        for fileName in fileNames where fileName.hasSuffix(".jpg") {
            // File names are formatted as "{UUID}-screenN.jpg"
            // Extract the UUID prefix to check if this message is still active
            let uuidString = fileName
                .components(separatedBy: "-screen")
                .first ?? ""
            if let fileMessageID = UUID(uuidString: uuidString), !activeIDs.contains(fileMessageID) {
                let fileURL = screenshotsDirectoryURL.appendingPathComponent(fileName)
                try? FileManager.default.removeItem(at: fileURL)
                deletedCount += 1
            }
        }

        if deletedCount > 0 {
            print("🗂️ ChatHistoryStore: Deleted \(deletedCount) orphaned screenshot file(s)")
        }
    }
}
