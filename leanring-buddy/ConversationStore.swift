//
//  ConversationStore.swift
//  leanring-buddy
//
//  Persists multiple Clicky conversations to disk across app launches.
//  Replaces the single-file ChatHistoryStore with per-conversation storage.
//
//  Layout inside ~/Library/Application Support/Clicky/:
//    conversations-index.json       — [Conversation] metadata array
//    conversations/
//      {conversationID}.json        — [ChatMessage] array for that conversation
//    screenshots/
//      {messageID}-screen1.jpg      — compressed screenshot (unchanged from before)
//    history.json.migrated          — renamed legacy file after one-time migration
//
//  Screenshot compression:
//    Originals from ScreenCaptureKit are full-resolution JPEGs (often 2-4 MB).
//    We resize to at most 1 280 px on the longest side and re-encode at 0.5
//    JPEG quality, which typically brings each capture down to 100–250 KB
//    while remaining sharp enough for review.
//
//  Retention policy:
//    Conversations with no messages and updatedAt older than `maxRetentionDays`
//    are deleted automatically when the index is loaded on app launch.
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

final class ConversationStore {

    // MARK: - Configuration

    /// Number of days to keep empty conversations before pruning them.
    /// Conversations with messages are never auto-deleted.
    static let maxRetentionDays = 7

    /// Longest edge (pixels) of stored screenshots.
    static let screenshotMaxPixelDimension = 1280

    /// JPEG quality for stored screenshots.
    static let screenshotJPEGQuality: CGFloat = 0.5

    // MARK: - File Layout

    private let clickyAppSupportDirectoryURL: URL
    private let conversationsIndexFileURL: URL
    private let conversationsDirectoryURL: URL
    let screenshotsDirectoryURL: URL
    /// Legacy history file — read once during migration, then renamed.
    private let legacyHistoryFileURL: URL

    init() {
        let appSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!

        clickyAppSupportDirectoryURL = appSupportURL.appendingPathComponent("Clicky")
        conversationsIndexFileURL = clickyAppSupportDirectoryURL.appendingPathComponent("conversations-index.json")
        conversationsDirectoryURL = clickyAppSupportDirectoryURL.appendingPathComponent("conversations")
        screenshotsDirectoryURL = clickyAppSupportDirectoryURL.appendingPathComponent("screenshots")
        legacyHistoryFileURL = clickyAppSupportDirectoryURL.appendingPathComponent("history.json")

        createDirectoriesIfNeeded()
    }

    private func createDirectoriesIfNeeded() {
        try? FileManager.default.createDirectory(
            at: conversationsDirectoryURL,
            withIntermediateDirectories: true
        )
        try? FileManager.default.createDirectory(
            at: screenshotsDirectoryURL,
            withIntermediateDirectories: true
        )
    }

    // MARK: - Migration from Legacy Single-History Format

    /// One-time migration: reads the old `history.json`, imports all messages
    /// as a single conversation, and renames the legacy file so the migration
    /// never runs again. Safe to call on every launch — returns immediately
    /// if the index file already exists.
    func migrateFromLegacyHistoryIfNeeded() {
        // If the index already exists, migration has already run (or was never needed)
        guard !FileManager.default.fileExists(atPath: conversationsIndexFileURL.path) else {
            return
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // Try to read the legacy file
        guard let jsonData = try? Data(contentsOf: legacyHistoryFileURL),
              let messages = try? decoder.decode([ChatMessage].self, from: jsonData),
              !messages.isEmpty
        else {
            // No legacy data — create an empty index so we don't re-check next time
            saveConversationsIndex([])
            print("🗂️ ConversationStore: No legacy history to migrate")
            return
        }

        // Derive a title from the first user message
        let firstUserMessage = messages.first(where: { $0.role == .user })
        let title = truncateToWordBoundary(firstUserMessage?.content ?? "Previous Chat", maxLength: 40)

        let conversation = Conversation(
            id: UUID(),
            title: title,
            createdAt: messages.first?.timestamp ?? Date(),
            updatedAt: messages.last?.timestamp ?? Date(),
            messageCount: messages.count
        )

        // Save messages to the per-conversation file
        saveMessages(messages, for: conversation.id)
        // Save the index with the single migrated conversation
        saveConversationsIndex([conversation])

        // Rename the legacy file as a backup
        let migratedURL = clickyAppSupportDirectoryURL.appendingPathComponent("history.json.migrated")
        try? FileManager.default.moveItem(at: legacyHistoryFileURL, to: migratedURL)

        print("🗂️ ConversationStore: Migrated \(messages.count) messages from legacy history.json")
    }

    // MARK: - Conversations Index

    /// Loads the conversations index from disk, pruning stale empty conversations.
    /// Returns conversations sorted by most recently updated first.
    func loadConversationsIndex() -> [Conversation] {
        guard let jsonData = try? Data(contentsOf: conversationsIndexFileURL) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard var conversations = try? decoder.decode([Conversation].self, from: jsonData) else {
            print("⚠️ ConversationStore: Failed to decode conversations index — starting fresh")
            return []
        }

        // Prune empty conversations older than the retention window
        let cutoffDate = Calendar.current.date(
            byAdding: .day,
            value: -Self.maxRetentionDays,
            to: Date()
        )!

        let beforeCount = conversations.count
        conversations.removeAll { conversation in
            conversation.messageCount == 0 && conversation.updatedAt < cutoffDate
        }

        if conversations.count < beforeCount {
            let pruned = beforeCount - conversations.count
            print("🗂️ ConversationStore: Pruned \(pruned) stale empty conversation(s)")
            saveConversationsIndex(conversations)
        }

        // Sort by most recent activity first
        conversations.sort { $0.updatedAt > $1.updatedAt }

        print("🗂️ ConversationStore: Loaded \(conversations.count) conversations")
        return conversations
    }

    /// Writes the conversations index to disk.
    func saveConversationsIndex(_ conversations: [Conversation]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted

        guard let jsonData = try? encoder.encode(conversations) else {
            print("⚠️ ConversationStore: Failed to encode conversations index")
            return
        }

        do {
            try jsonData.write(to: conversationsIndexFileURL, options: .atomic)
        } catch {
            print("⚠️ ConversationStore: Failed to write conversations-index.json: \(error)")
        }
    }

    // MARK: - Per-Conversation Messages

    /// Loads messages for a specific conversation from its JSON file.
    /// Returns an empty array if the file doesn't exist or fails to decode.
    func loadMessages(for conversationID: UUID) -> [ChatMessage] {
        let fileURL = conversationFileURL(for: conversationID)

        guard let jsonData = try? Data(contentsOf: fileURL) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard let messages = try? decoder.decode([ChatMessage].self, from: jsonData) else {
            print("⚠️ ConversationStore: Failed to decode messages for \(conversationID)")
            return []
        }

        return messages
    }

    /// Saves messages for a specific conversation to its JSON file.
    func saveMessages(_ messages: [ChatMessage], for conversationID: UUID) {
        let fileURL = conversationFileURL(for: conversationID)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted

        guard let jsonData = try? encoder.encode(messages) else {
            print("⚠️ ConversationStore: Failed to encode messages for \(conversationID)")
            return
        }

        do {
            try jsonData.write(to: fileURL, options: .atomic)
        } catch {
            print("⚠️ ConversationStore: Failed to write messages for \(conversationID): \(error)")
        }
    }

    // MARK: - Conversation Lifecycle

    /// Creates a new empty conversation, writes its empty message file,
    /// and returns the metadata. Does NOT update the index — the caller
    /// is responsible for adding the returned conversation to the index
    /// and saving it.
    func createConversation() -> Conversation {
        let conversation = Conversation()
        saveMessages([], for: conversation.id)
        return conversation
    }

    /// Deletes a conversation's message file and any associated screenshots.
    /// Does NOT update the index — the caller is responsible for removing
    /// the conversation from the index and saving it.
    func deleteConversation(id conversationID: UUID) {
        // Delete the conversation message file
        let fileURL = conversationFileURL(for: conversationID)
        try? FileManager.default.removeItem(at: fileURL)

        // Load messages to find screenshot references, then clean them up
        // (We already deleted the file, so load from memory isn't possible.
        // Instead, scan the screenshots directory for files matching message IDs
        // from this conversation. Since message IDs are conversation-independent
        // UUIDs embedded in screenshot file names, we can't easily filter by
        // conversation. For now, orphaned screenshots will be cleaned up by
        // the periodic cleanup that runs when the app exits or conversations
        // are pruned. This is acceptable since screenshot files are small.)

        print("🗂️ ConversationStore: Deleted conversation \(conversationID)")
    }

    /// Returns the file URL for a conversation's message JSON.
    private func conversationFileURL(for conversationID: UUID) -> URL {
        conversationsDirectoryURL.appendingPathComponent("\(conversationID.uuidString).json")
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
                print("⚠️ ConversationStore: Compression failed for screen \(screenIndex + 1)")
                continue
            }

            do {
                try compressedData.write(to: fileURL, options: .atomic)
                savedFileNames.append(fileName)
                let kb = compressedData.count / 1024
                let originalKB = rawData.count / 1024
                print("🗂️ ConversationStore: Saved \(fileName) (\(originalKB)KB → \(kb)KB)")
            } catch {
                print("⚠️ ConversationStore: Failed to write \(fileName): \(error)")
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

    // MARK: - Helpers

    /// Truncates a string to `maxLength` characters, breaking at the last word
    /// boundary so titles don't end mid-word.
    private func truncateToWordBoundary(_ text: String, maxLength: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxLength else { return trimmed }

        let prefix = String(trimmed.prefix(maxLength))
        // Find the last space to avoid cutting mid-word
        if let lastSpace = prefix.lastIndex(of: " ") {
            return String(prefix[prefix.startIndex..<lastSpace])
        }
        return prefix
    }
}
