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
    private var sparkleUpdaterController: SPUStandardUpdaterController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Mirror stdout/stderr to a log file so logs are captured even when the
        // app is launched via Finder/open (no terminal to inherit stdout). Then
        // line-buffer so entries flush in real time. Read it at:
        //   ~/Library/Logs/joceclicky.log
        let logPath = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs/joceclicky.log")
        freopen(logPath, "a", stdout)
        freopen(logPath, "a", stderr)
        setvbuf(stdout, nil, _IOLBF, 0)
        print("🎯 Clicky: Starting...")
        print("🎯 Clicky: Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")")

        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 0])

        ClickyAnalytics.configure()
        ClickyAnalytics.trackAppOpened()

        menuBarPanelManager = MenuBarPanelManager(companionManager: companionManager)
        companionManager.start()
        // Auto-open the panel if the user still needs to do something:
        // either they haven't onboarded yet, or permissions were revoked.
        if !companionManager.hasCompletedOnboarding || !companionManager.allPermissionsGranted {
            menuBarPanelManager?.showPanelOnLaunch()
        }
        registerAsLoginItemIfNeeded()
        // Apply the persisted Dock-visibility preference (default: notch only).
        DockVisibility.apply(showInDock: DockVisibility.isShownInDock)
        startSparkleUpdater()
    }

    func applicationWillTerminate(_ notification: Notification) {
        companionManager.stop()
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

    private func startSparkleUpdater() {
        let updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.sparkleUpdaterController = updaterController
        SparkleUpdater.shared = updaterController

        // The bundled appcast (SUFeedURL) points at the UPSTREAM app's feed, not
        // this fork's. Disable automatic/background checks so joceclicky never
        // silently offers to "update" itself into the upstream app. The manual
        // "Check for Updates" button stays available for when a fork-owned
        // appcast is configured.
        updaterController.updater.automaticallyChecksForUpdates = false
        do {
            try updaterController.updater.start()
        } catch {
            print("⚠️ Clicky: Sparkle updater failed to start: \(error)")
        }
    }
}

/// Tiny shared accessor so in-app surfaces (e.g. the Notch Settings tab) can
/// trigger "Check for Updates…" without holding a reference to the AppDelegate.
@MainActor
enum SparkleUpdater {
    static var shared: SPUStandardUpdaterController?

    /// Presents Sparkle's "Check for Updates" UI if the updater is running.
    static func checkForUpdates() {
        shared?.checkForUpdates(nil)
    }

    /// Whether the updater is available (started successfully).
    static var isAvailable: Bool { shared != nil }
}
