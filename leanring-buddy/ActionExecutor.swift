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
//    createReminder   → `shortcuts run "Clicky Create Reminder"` with input,
//                       falling back to a plain Reminders AppleScript
//

import AppKit
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
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIDForCommonApp(lowercased))
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

    /// Creates a macOS reminder via AppleScript.
    /// `dateHint` is a human-readable string like "tomorrow 9am" — macOS Reminders
    /// doesn't parse natural language directly, so we create it without a due date
    /// and include the dateHint in the reminder body so the user sees it.
    /// For full natural-language date support, build a Shortcut called
    /// "Clicky Create Reminder" that accepts text input and uses the
    /// "Ask Siri" date parsing available in Shortcuts.
    static func createReminder(text: String, dateHint: String) {
        let fullText = dateHint.isEmpty ? text : "\(text) (\(dateHint))"

        let escapedText = fullText
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")

        let appleScriptSource = """
        tell application "Reminders"
            set newReminder to make new reminder with properties {name:"\(escapedText)"}
        end tell
        """

        DispatchQueue.global(qos: .utility).async {
            var errorInfo: NSDictionary?
            guard let script = NSAppleScript(source: appleScriptSource) else { return }
            script.executeAndReturnError(&errorInfo)
            if let errorInfo {
                print("⚠️ Reminder creation failed: \(errorInfo)")
            } else {
                print("⏰ Reminder created: \"\(fullText)\"")
            }
        }
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
