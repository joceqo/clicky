//
//  leanring_buddyApp.swift
//  leanring-buddy
//
//  Menu bar-only companion app. No dock icon, no main window — just an
//  always-available status item in the macOS menu bar. Clicking the icon
//  opens a floating panel with companion voice controls.
//

import ServiceManagement
import SwiftUI
import Sparkle

@main
struct leanring_buddyApp: App {
    @NSApplicationDelegateAdaptor(CompanionAppDelegate.self) var appDelegate

    var body: some Scene {
        // The app lives entirely in the menu bar panel managed by the AppDelegate.
        // This empty Settings scene satisfies SwiftUI's requirement for at least
        // one scene but is never shown (LSUIElement=true removes the app menu).
        Settings {
            EmptyView()
        }
    }
}

/// Manages the companion lifecycle: creates the menu bar panel and starts
/// the companion voice pipeline on launch.
@MainActor
final class CompanionAppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarPanelManager: MenuBarPanelManager?
    private let companionManager = CompanionManager()
    private var chatWindowController: ChatWindowController?
    private var sparkleUpdaterController: SPUStandardUpdaterController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🎯 Clicky: Starting...")
        print("🎯 Clicky: Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")")

        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 0])

        ClickyAnalytics.configure()
        ClickyAnalytics.trackAppOpened()

        registerURLSchemeHandler()

        menuBarPanelManager = MenuBarPanelManager(companionManager: companionManager)
        chatWindowController = ChatWindowController(companionManager: companionManager)
        companionManager.start()
        // Auto-open the panel if the user still needs to do something:
        // either they haven't onboarded yet, or permissions were revoked.
        if !companionManager.hasCompletedOnboarding || !companionManager.allPermissionsGranted {
            menuBarPanelManager?.showPanelOnLaunch()
        }
        registerAsLoginItemIfNeeded()
        // startSparkleUpdater()
    }

    func applicationWillTerminate(_ notification: Notification) {
        companionManager.stop()
    }

    /// Called when the user clicks the Clicky dock icon while the app is already running.
    /// Always shows the chat window — this is the primary action for the dock icon.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        chatWindowController?.showChatWindow()
        return true
    }

    /// Registers the app as a login item so it launches automatically on
    /// startup. Uses SMAppService which shows the app in System Settings >
    /// General > Login Items, letting the user toggle it off if they want.
    private func registerAsLoginItemIfNeeded() {
        let loginItemService = SMAppService.mainApp
        if loginItemService.status != .enabled {
            do {
                try loginItemService.register()
                print("🎯 Clicky: Registered as login item")
            } catch {
                print("⚠️ Clicky: Failed to register as login item: \(error)")
            }
        }
    }

    /// Installs the `kAEGetURL` Apple Event handler so macOS delivers
    /// `clicky://` URLs to us. The Claude Code Stop hook opens
    /// `clicky://speak?file=<path>` (or `?text=<urlencoded>`) after each
    /// assistant turn so Clicky can read the response aloud.
    private func registerURLSchemeHandler() {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor,
                                       withReplyEvent reply: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: urlString) else {
            return
        }
        handleClickyURL(url)
    }

    /// Parses a `clicky://` URL and dispatches it. Currently only
    /// `clicky://speak` is implemented. Two ways to pass the text:
    /// `?text=<urlencoded>` for short strings, `?file=<absolute-path>` for
    /// long strings that would blow past the URL length limit.
    private func handleClickyURL(_ url: URL) {
        guard url.scheme?.lowercased() == "clicky" else { return }
        guard let action = url.host?.lowercased(), action == "speak" else {
            print("⚠️ Clicky: unknown clicky:// action: \(url.host ?? "(none)")")
            return
        }

        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let fileParameter = queryItems.first(where: { $0.name == "file" })?.value
        let textParameter = queryItems.first(where: { $0.name == "text" })?.value

        let spokenText: String?
        if let filePath = fileParameter, !filePath.isEmpty {
            spokenText = try? String(contentsOfFile: filePath, encoding: .utf8)
            // Opportunistic cleanup — the hook writes to /tmp and expects us
            // to consume the file. Ignore errors; stale tmp files are harmless.
            if spokenText != nil { try? FileManager.default.removeItem(atPath: filePath) }
        } else if let inlineText = textParameter {
            spokenText = inlineText
        } else {
            spokenText = nil
        }

        guard let textToSpeak = spokenText, !textToSpeak.isEmpty else {
            print("⚠️ Clicky: clicky://speak received but no text to speak")
            return
        }
        companionManager.speakExternalText(textToSpeak)
    }

    private func startSparkleUpdater() {
        let updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.sparkleUpdaterController = updaterController

        do {
            try updaterController.updater.start()
        } catch {
            print("⚠️ Clicky: Sparkle updater failed to start: \(error)")
        }
    }
}
