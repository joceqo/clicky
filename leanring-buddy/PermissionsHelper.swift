//
//  PermissionsHelper.swift
//  leanring-buddy
//
//  Self-contained permissions helper UX. Inspired by zats/permiso, but
//  implemented natively (no SPM dependency) for reliability against the
//  Xcode 16 file-system-synchronized project structure.
//
//  It detects the three permissions the app needs — Screen Recording,
//  Accessibility, and Microphone — guides the user to the exact System
//  Settings privacy pane, triggers the OS add-prompt where possible, and
//  (the key dev-build pain point) surfaces the running app's bundle path
//  with a "Reveal in Finder" button so the user can drag the exact build
//  into the Settings list.
//
//  Detection / request logic is centralized in WindowPositionManager and
//  reused here so there is a single source of truth.
//

import AppKit
import AVFoundation
import Permiso
import SwiftUI

// MARK: - Permission Model

/// The three privacy permissions joceclicky needs to function.
enum AppPermission: String, CaseIterable, Identifiable {
    case screenRecording
    case accessibility
    case microphone

    var id: String { rawValue }

    /// Human-readable name shown in the UI.
    var title: String {
        switch self {
        case .screenRecording: return "Screen Recording"
        case .accessibility: return "Accessibility"
        case .microphone: return "Microphone"
        }
    }

    /// SF Symbol used for the row icon.
    var iconName: String {
        switch self {
        case .screenRecording: return "rectangle.dashed.badge.record"
        case .accessibility: return "hand.raised"
        case .microphone: return "mic"
        }
    }

    /// Short explanation of why the permission is needed.
    var rationale: String {
        switch self {
        case .screenRecording:
            return "Lets Clicky see your screen to answer questions about it. Only captured when you press the hotkey."
        case .accessibility:
            return "Lets Clicky read on-screen elements and point its cursor at them."
        case .microphone:
            return "Lets Clicky hear you when you hold the push-to-talk shortcut."
        }
    }

    /// The exact `x-apple.systempreferences:` deep link to the privacy pane.
    var settingsURLString: String {
        switch self {
        case .screenRecording:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        case .accessibility:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .microphone:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        }
    }
}

// MARK: - Permissions Helper

/// Static facade over the native detection + request APIs. Mirrors the shape of
/// `PermisoAssistant.shared.present(panel:)` but uses the codebase's existing,
/// battle-tested logic in `WindowPositionManager`.
@MainActor
enum PermissionsHelper {

    /// Live status for a single permission.
    static func isGranted(_ permission: AppPermission) -> Bool {
        switch permission {
        case .screenRecording: return WindowPositionManager.hasScreenRecordingPermission()
        case .accessibility: return WindowPositionManager.hasAccessibilityPermission()
        case .microphone: return WindowPositionManager.hasMicrophonePermission()
        }
    }

    /// Triggers the OS add-prompt where possible, otherwise opens the exact
    /// System Settings privacy pane. Safe to call repeatedly.
    @discardableResult
    static func request(_ permission: AppPermission) -> PermissionRequestPresentationDestination {
        switch permission {
        case .screenRecording: return WindowPositionManager.requestScreenRecordingPermission()
        case .accessibility:
            // Permiso's guided overlay (drag-the-icon-into-the-list panel) +
            // the native AX prompt. request(_:) runs from the SwiftUI button
            // action, i.e. already on the main actor.
            MainActor.assumeIsolated {
                PermisoAssistant.shared.present(panel: .accessibility)
            }
            return WindowPositionManager.requestAccessibilityPermission()
        case .microphone: return WindowPositionManager.requestMicrophonePermission()
        }
    }

    /// Opens the exact System Settings privacy pane for the permission.
    static func openSettings(for permission: AppPermission) {
        guard let url = URL(string: permission.settingsURLString) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - App Bundle (the dev-build pain point)

    /// The filesystem path of the currently running app bundle. This is the
    /// non-obvious bit for Debug builds — the user needs to know exactly which
    /// `.app` to add to the Settings privacy list.
    static var bundlePath: String { Bundle.main.bundlePath }

    /// Reveals the running app bundle in Finder so the user can drag the exact
    /// build into a Settings privacy list when it doesn't appear automatically
    /// (common with unsigned dev builds).
    static func revealAppInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    /// Copies the bundle path to the clipboard for easy pasting.
    static func copyBundlePathToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(bundlePath, forType: .string)
    }
}

// MARK: - Permissions Setup View

/// A focused, self-contained permissions panel. Renders one row per missing
/// permission (with Grant + "Open Settings" actions) and a prominent card that
/// surfaces the app's bundle path with Reveal-in-Finder + Copy actions.
///
/// Designed to drop into the menu-bar panel; styled with the app design system.
struct PermissionsSetupView: View {
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("PERMISSIONS")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(DS.Colors.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)

            ForEach(AppPermission.allCases) { permission in
                PermissionRowView(permission: permission, isGranted: isGranted(permission))
            }

            // The key dev-build helper — always shown so the user can find the
            // exact build to add, even after permissions are granted.
            bundlePathCard
        }
    }

    private func isGranted(_ permission: AppPermission) -> Bool {
        switch permission {
        case .screenRecording: return companionManager.hasScreenRecordingPermission
        case .accessibility: return companionManager.hasAccessibilityPermission
        case .microphone: return companionManager.hasMicrophonePermission
        }
    }

    // MARK: - Bundle Path Card

    private var bundlePathCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "app.badge.checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.accentText)
                Text("Add THIS build to the list")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Text("macOS asks you to pick the app. For dev builds the path is non-obvious — this is the exact one:")
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            Text(PermissionsHelper.bundlePath)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(DS.Colors.codeText)
                .textSelection(.enabled)
                .lineLimit(3)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                        .fill(Color.black.opacity(0.25))
                )

            HStack(spacing: 8) {
                Button(action: {
                    PermissionsHelper.revealAppInFinder()
                }) {
                    HStack(spacing: 5) {
                        Image(systemName: "folder")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Reveal in Finder")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundColor(DS.Colors.textOnAccent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                            .fill(DS.Colors.accent)
                    )
                }
                .buttonStyle(.plain)
                .pointerCursor()

                Button(action: {
                    PermissionsHelper.copyBundlePathToClipboard()
                }) {
                    HStack(spacing: 5) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Copy path")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundColor(DS.Colors.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                            .stroke(DS.Colors.borderSubtle, lineWidth: 0.8)
                    )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .fill(DS.Colors.surface2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
        )
    }
}

// MARK: - Permission Row

/// A single permission row: icon + title + status, with Grant and
/// "Open Settings" actions when the permission is missing.
private struct PermissionRowView: View {
    let permission: AppPermission
    let isGranted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: permission.iconName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                        .frame(width: 16)

                    Text(permission.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                }

                Spacer()

                if isGranted {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(DS.Colors.success)
                            .frame(width: 6, height: 6)
                        Text("Granted")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(DS.Colors.success)
                    }
                } else {
                    HStack(spacing: 6) {
                        Button(action: {
                            PermissionsHelper.request(permission)
                        }) {
                            Text("Grant")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(DS.Colors.textOnAccent)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(DS.Colors.accent))
                        }
                        .buttonStyle(.plain)
                        .pointerCursor()

                        Button(action: {
                            PermissionsHelper.openSettings(for: permission)
                        }) {
                            Text("Settings")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(DS.Colors.textSecondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Capsule().stroke(DS.Colors.borderSubtle, lineWidth: 0.8))
                        }
                        .buttonStyle(.plain)
                        .pointerCursor()
                    }
                }
            }

            if !isGranted {
                Text(permission.rationale)
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 24)
            }
        }
        .padding(.vertical, 4)
    }
}
