//
//  ActionExecutor.swift
//  leanring-buddy
//
//  Executes the actions extracted by ActionTagParser. All actions run
//  in the background and never block the main actor, TTS playback, or UI.
//
//  Supported actions:
//    openURLOrApp     → NSWorkspace.open (URL) or NSWorkspace.openApplication
//    runShortcut      → `shortcuts run "name"` via Process
//    createReminder   → EventKit EKReminder with NSDataDetector date parsing
//

import AppKit
import EventKit
import Foundation

enum ActionExecutor {

    // MARK: - Open URL or app

    /// Opens a URL in the default browser, or launches a macOS app by name.
    /// Runs on the main actor because NSWorkspace requires it.
    @MainActor
    static func openURLOrApp(_ target: String) {
        // If it looks like a URL, open it directly
        if target.hasPrefix("http://") || target.hasPrefix("https://") {
            guard let url = URL(string: target) else {
                print("⚠️ ActionExecutor [OPEN]: invalid URL: \(target)")
                return
            }
            NSWorkspace.shared.open(url)
            print("🔗 Opened URL: \(target)")
            return
        }

        // Otherwise treat it as an app name and try to launch it.
        // NSWorkspace.openApplication requires the bundle URL, so we use
        // a Launch Services search via the app name.
        let lowercased = target.lowercased()
        if let appURL = bundleIDForCommonApp(lowercased).flatMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) })
            ?? findAppByName(target) {
            NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
            print("🚀 Opened app: \(target)")
        } else {
            // Last resort: try opening as if it's an app name via `open` CLI
            runProcess(launchPath: "/usr/bin/open", arguments: ["-a", target])
            print("🚀 Attempted to open app via CLI: \(target)")
        }
    }

    // MARK: - Run Apple Shortcut

    /// Runs an Apple Shortcut by name using the `shortcuts` CLI.
    /// The shortcut receives no input — it must be self-contained.
    static func runShortcut(named shortcutName: String) {
        runProcess(launchPath: "/usr/bin/shortcuts", arguments: ["run", shortcutName])
        print("⚡ Ran Shortcut: \"\(shortcutName)\"")
    }

    // MARK: - Create Reminder

    /// Creates a macOS reminder via EventKit.
    /// `dateHint` is a human-readable string like "tomorrow 9am" — NSDataDetector
    /// parses it into a real Date so the reminder has an actual due date and alarm,
    /// not just text in the title. Falls back to no due date if parsing fails.
    static func createReminder(text: String, dateHint: String) async {
        let store = EKEventStore()

        // Request Reminders access — the system shows the permission dialog once,
        // then caches the decision. macOS 14+ has a dedicated async method.
        let accessGranted: Bool
        if #available(macOS 14.0, *) {
            accessGranted = (try? await store.requestFullAccessToReminders()) ?? false
        } else {
            accessGranted = await withCheckedContinuation { continuation in
                store.requestAccess(to: .reminder) { granted, _ in
                    continuation.resume(returning: granted)
                }
            }
        }

        guard accessGranted else {
            print("⚠️ EventKit: Reminders access denied — cannot create reminder")
            return
        }

        let reminder = EKReminder(eventStore: store)
        reminder.title = text
        reminder.calendar = store.defaultCalendarForNewReminders()

        // Try to parse the date hint into a real due date + alarm.
        // NSDataDetector handles natural language like "tomorrow 9am", "next Friday",
        // "in 2 hours", etc. The reminder body stays clean (just the title text).
        if !dateHint.isEmpty, let parsedDueDate = parseDate(from: dateHint) {
            let dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: parsedDueDate
            )
            reminder.dueDateComponents = dueDateComponents
            reminder.addAlarm(EKAlarm(absoluteDate: parsedDueDate))
            print("⏰ Reminder created via EventKit: \"\(text)\" due \(parsedDueDate)")
        } else {
            print("⏰ Reminder created via EventKit: \"\(text)\" (no parsed date for hint: \"\(dateHint)\")")
        }

        do {
            try store.save(reminder, commit: true)
        } catch {
            print("⚠️ EventKit: reminder save failed — \(error)")
        }
    }

    /// Uses NSDataDetector to extract a Date from a natural-language hint like
    /// "tomorrow 9am" or "next Friday at 3pm". Returns nil if no date is found.
    private static func parseDate(from hint: String) -> Date? {
        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.date.rawValue
        ) else { return nil }
        let range = NSRange(hint.startIndex..., in: hint)
        return detector.matches(in: hint, range: range).first?.date
    }

    // MARK: - Private helpers

    /// Runs a command-line process in the background. Does not capture output.
    private static func runProcess(launchPath: String, arguments: [String]) {
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.launchPath = launchPath
            process.arguments = arguments
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                print("⚠️ ActionExecutor process failed (\(launchPath) \(arguments)): \(error)")
            }
        }
    }

    /// Maps common app names to their bundle identifiers for reliable lookup.
    private static func bundleIDForCommonApp(_ lowercasedName: String) -> String? {
        let knownApps: [String: String] = [
            "xcode":             "com.apple.dt.Xcode",
            "safari":            "com.apple.Safari",
            "chrome":            "com.google.Chrome",
            "firefox":           "org.mozilla.firefox",
            "terminal":          "com.apple.Terminal",
            "iterm":             "com.googlecode.iterm2",
            "iterm2":            "com.googlecode.iterm2",
            "notes":             "com.apple.Notes",
            "reminders":         "com.apple.reminders",
            "calendar":          "com.apple.iCal",
            "mail":              "com.apple.mail",
            "messages":          "com.apple.MobileSMS",
            "slack":             "com.tinyspeck.slackmacgap",
            "notion":            "notion.id",
            "figma":             "com.figma.Desktop",
            "davinci resolve":   "com.blackmagic-design.DaVinciResolve",
            "resolve":           "com.blackmagic-design.DaVinciResolve",
            "spotify":           "com.spotify.client",
            "music":             "com.apple.Music",
            "finder":            "com.apple.finder",
            "vscode":            "com.microsoft.VSCode",
            "visual studio code":"com.microsoft.VSCode",
        ]
        return knownApps[lowercasedName]
    }

    /// Searches installed applications by display name using Launch Services.
    private static func findAppByName(_ appName: String) -> URL? {
        let lowercased = appName.lowercased()
        let appDirectories = [
            "/Applications",
            "/System/Applications",
            "\(NSHomeDirectory())/Applications"
        ]
        for directory in appDirectories {
            let url = URL(fileURLWithPath: directory)
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil
            ) else { continue }
            for appURL in contents where appURL.pathExtension == "app" {
                let name = appURL.deletingPathExtension().lastPathComponent.lowercased()
                if name == lowercased || name.contains(lowercased) {
                    return appURL
                }
            }
        }
        return nil
    }
}
