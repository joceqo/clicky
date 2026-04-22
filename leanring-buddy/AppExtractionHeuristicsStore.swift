//
//  AppExtractionHeuristicsStore.swift
//  leanring-buddy
//
//  Per-app outcome tracker for the read-aloud extraction pipeline. Lets the
//  pipeline skip strategies that have repeatedly failed for a given bundle ID
//  so the user doesn't pay the AX-tree-walk cost every time they hit ⌃⇧L on
//  Chrome/Electron/VS Code.
//
//  Persisted to UserDefaults as JSON, keyed on bundle ID. Records expire
//  after `entryExpiryInterval` so transient AX breakage (app update, a11y
//  permission reset) doesn't permanently lock us onto an OCR-only path.
//

import Foundation

final class AppExtractionHeuristicsStore {

    // MARK: - Tunables

    /// How long a record stays valid. After this, we re-probe from scratch.
    private static let entryExpiryInterval: TimeInterval = 7 * 24 * 60 * 60

    /// How long an AX failure keeps us on the skip-AX fast path. Short
    /// enough that the user notices an app becoming AX-friendly again
    /// within minutes, long enough to cover a normal reading session.
    private static let axFailureCacheInterval: TimeInterval = 5 * 60

    // MARK: - Record

    struct Record: Codable {
        /// Bundle identifier of the target app (e.g. com.google.Chrome).
        var bundleID: String
        /// Was the last AX attempt useful (words with non-zero bounds)?
        /// `nil` = never tried. `false` = known-useless (use OCR).
        var axLastKnownWorking: Bool?
        /// Timestamp of the last AX attempt — caps how long we trust a
        /// `false` value before re-probing.
        var axLastAttemptAt: Date?
        /// Running average of word count returned by successful AX calls.
        /// Lets us spot "AX technically works but only returns a handful
        /// of words" apps (menubar-heavy clients) where OCR gives more.
        var averageAXWordCount: Double?
        /// Total number of times we've observed this app — weights the
        /// running average.
        var observationCount: Int
        /// Last time this record was touched. Drives expiry.
        var lastUpdated: Date
    }

    // MARK: - Storage

    private static let userDefaultsKey = "appExtractionHeuristics"
    private var recordsByBundleID: [String: Record] = [:]

    init() {
        loadFromDisk()
    }

    // MARK: - Queries

    /// True if the app has failed AX recently enough that we should skip
    /// straight to OCR on this trigger. Falls back to false (= try AX) for
    /// unknown apps so first-time users of a given app still get the AX
    /// fast path.
    func shouldSkipAccessibility(forBundleID bundleID: String?) -> Bool {
        guard let bundleID, let record = recordsByBundleID[bundleID] else { return false }
        guard record.axLastKnownWorking == false else { return false }
        guard let lastAttemptAt = record.axLastAttemptAt else { return false }
        return Date().timeIntervalSince(lastAttemptAt) < Self.axFailureCacheInterval
    }

    // MARK: - Updates

    /// Records the outcome of an extraction attempt so future triggers on
    /// the same app can skip paths we know are unproductive.
    ///
    /// - Parameters:
    ///   - bundleID: The frontmost app's bundle ID at trigger time.
    ///   - source: Which strategy actually produced the result.
    ///   - wordCount: Total words returned (independent of whether they
    ///                had screen bounds).
    ///   - wordsWithBounds: Subset of words with non-zero screen bounds.
    ///                     AX returning `words` but zero-bounds is the
    ///                     "AX is useless" signal.
    func recordExtractionOutcome(
        bundleID: String?,
        source: ScreenTextExtractionSource,
        wordCount: Int,
        wordsWithBounds: Int
    ) {
        guard let bundleID else { return }

        var record = recordsByBundleID[bundleID] ?? Record(
            bundleID: bundleID,
            axLastKnownWorking: nil,
            axLastAttemptAt: nil,
            averageAXWordCount: nil,
            observationCount: 0,
            lastUpdated: Date()
        )

        switch source {
        case .accessibility:
            // AX was the winning strategy. Update working-state + running
            // average. `wordsWithBounds > 0` is the success signal; AX
            // returning just text with no geometry is treated as useless
            // because the cursor slicer can't anchor without bounds.
            let axDidProduceUsableBounds = wordsWithBounds > 0
            record.axLastKnownWorking = axDidProduceUsableBounds
            record.axLastAttemptAt = Date()
            if axDidProduceUsableBounds {
                if let previousAverage = record.averageAXWordCount {
                    let weightedSum = previousAverage * Double(record.observationCount) + Double(wordCount)
                    record.averageAXWordCount = weightedSum / Double(record.observationCount + 1)
                } else {
                    record.averageAXWordCount = Double(wordCount)
                }
            }
        case .ocr:
            // OCR ran — either AX was skipped (via this cache) or AX was
            // tried and gave nothing usable. Only downgrade AX to "known
            // useless" if we hadn't seen it work recently; otherwise a
            // transient failure would evict a good record.
            if record.axLastKnownWorking != true {
                record.axLastKnownWorking = false
                record.axLastAttemptAt = Date()
            }
        }

        record.observationCount += 1
        record.lastUpdated = Date()
        recordsByBundleID[bundleID] = record
        saveToDisk()
    }

    // MARK: - Persistence

    private func loadFromDisk() {
        guard let data = UserDefaults.standard.data(forKey: Self.userDefaultsKey) else { return }
        guard let decoded = try? JSONDecoder().decode([String: Record].self, from: data) else {
            return
        }
        // Drop entries that are older than the expiry window so stale
        // "AX broken" beliefs don't survive a user upgrading the target
        // app after a long gap.
        let cutoffDate = Date().addingTimeInterval(-Self.entryExpiryInterval)
        recordsByBundleID = decoded.filter { $0.value.lastUpdated > cutoffDate }
    }

    private func saveToDisk() {
        guard let encoded = try? JSONEncoder().encode(recordsByBundleID) else { return }
        UserDefaults.standard.set(encoded, forKey: Self.userDefaultsKey)
    }
}
