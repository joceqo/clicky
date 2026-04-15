//
//  DailyReviewScheduler.swift
//  leanring-buddy
//
//  Schedules and manages the daily learning review local notification.
//  The notification fires once per day at the user-chosen hour, listing
//  topics learned in the past 24 hours and prompting the user to ask
//  Clicky to quiz them.
//
//  No quiz questions are pre-generated here — that keeps quality high by
//  letting Claude generate them fresh when the user opens the chat.
//

import Foundation
import UserNotifications

final class DailyReviewScheduler {

    private let notificationCenter = UNUserNotificationCenter.current()
    /// Stable identifier so we can cancel / replace without accumulating duplicates.
    private let notificationID = "com.clicky.dailyLearningReview"

    // MARK: - Permission

    /// Requests notification permission if the user hasn't been asked yet.
    /// Returns whether permission is currently granted after the request.
    func requestPermissionIfNeeded() async -> Bool {
        let settings = await notificationCenter.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            let granted = (try? await notificationCenter.requestAuthorization(options: [.alert, .sound])) ?? false
            return granted
        case .denied:
            return false
        @unknown default:
            return false
        }
    }

    // MARK: - Schedule

    /// Schedules (or reschedules) the daily review notification.
    /// Cancels any existing pending notification first to avoid duplicates.
    /// If `recentTopics` is empty, no notification is scheduled — nothing
    /// to review means no nudge is needed.
    func scheduleDailyReview(atHour hour: Int, recentTopics: [LearningEntry]) async {
        notificationCenter.removePendingNotificationRequests(withIdentifiers: [notificationID])

        guard !recentTopics.isEmpty else {
            print("🔔 DailyReview: no recent topics, skipping schedule")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "Learning review"
        content.body = buildNotificationBody(from: recentTopics)
        content.sound = .default

        // Fire at the specified hour every day (minute and second default to 0)
        var triggerComponents = DateComponents()
        triggerComponents.hour = hour
        triggerComponents.minute = 0
        let trigger = UNCalendarNotificationTrigger(dateMatching: triggerComponents, repeats: true)

        let request = UNNotificationRequest(
            identifier: notificationID,
            content: content,
            trigger: trigger
        )

        do {
            try await notificationCenter.add(request)
            print("🔔 DailyReview: scheduled for \(hour):00 with \(recentTopics.count) topic(s)")
        } catch {
            print("⚠️ DailyReview: failed to schedule — \(error)")
        }
    }

    /// Cancels the pending daily review notification.
    func cancelDailyReview() {
        notificationCenter.removePendingNotificationRequests(withIdentifiers: [notificationID])
        print("🔔 DailyReview: cancelled")
    }

    // MARK: - Private helpers

    /// Builds a concise notification body from recent learning entries.
    /// Caps at 3 topics so the banner stays readable. Always ends with
    /// the quiz prompt so the user knows what to do next.
    private func buildNotificationBody(from entries: [LearningEntry]) -> String {
        // Most recent entries first, cap at 3
        let topEntries = entries.suffix(3)
        let topicPhrases = topEntries.map { "\($0.topic) (\($0.app))" }

        let topicsText: String
        if topicPhrases.count == 1 {
            topicsText = topicPhrases[0]
        } else if topicPhrases.count == 2 {
            topicsText = topicPhrases.joined(separator: " and ")
        } else {
            let allButLast = topicPhrases.dropLast().joined(separator: ", ")
            topicsText = "\(allButLast) and \(topicPhrases.last!)"
        }

        return "Yesterday: \(topicsText). Ask Clicky to quiz you to lock it in."
    }
}
