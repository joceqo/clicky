//
//  NotchSettingsTab.swift
//  leanring-buddy
//
//  The Notch "Settings" surface, modeled on the in-notch Settings of the
//  commercial Clicky (4012): a sectioned, scrollable list grouping CUSTOMIZATION
//  links (Shortcuts / Voice / Microphone), a "Show in Dock" toggle, and
//  "UPDATES & SUPPORT → Check for Updates". It does NOT rebuild the full
//  settings — the customization rows and "Open full settings" all open the main
//  SettingsView window via SettingsWindowController.shared.
//

import SwiftUI

struct NotchSettingsTab: View {
    @ObservedObject var companionManager: CompanionManager

    /// Dock-visibility preference — shared with the Home tab's Dock/Undock button.
    @AppStorage(showInDockKey) private var showInDock: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                // CUSTOMIZATION — rows that open the main settings window.
                section("Customization") {
                    linkRow("Shortcuts", systemImage: "keyboard")
                    linkRow("Voice", systemImage: "waveform")
                    linkRow("Microphone", systemImage: "mic.fill")
                }

                // GENERAL — Show in Dock toggle (same setting as Home's button).
                section("General") {
                    Toggle(isOn: Binding(
                        get: { showInDock },
                        set: { newValue in
                            showInDock = newValue
                            DockVisibility.apply(showInDock: newValue)
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Show in Dock")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(DS.Colors.textPrimary)
                            Text("Turn off to keep Clicky notch only.")
                                .font(.system(size: 11))
                                .foregroundColor(DS.Colors.textTertiary)
                        }
                    }
                    .toggleStyle(.switch)
                    .tint(DS.Colors.accent)
                    .padding(.vertical, DS.Spacing.xs)
                    .padding(.horizontal, DS.Spacing.md)
                }

                // UPDATES & SUPPORT — Sparkle "Check for Updates".
                section("Updates & Support") {
                    actionRow("Check for Updates", systemImage: "arrow.triangle.2.circlepath") {
                        if SparkleUpdater.isAvailable {
                            SparkleUpdater.checkForUpdates()
                        } else {
                            // Fallback: updater not running — open full settings.
                            SettingsWindowController.shared.show(companionManager: companionManager)
                        }
                    }
                }

                // Escape hatch into the complete settings UI.
                Button {
                    SettingsWindowController.shared.show(companionManager: companionManager)
                } label: {
                    HStack(spacing: DS.Spacing.sm) {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 12, weight: .medium))
                        Text("Open full settings")
                            .font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundColor(DS.Colors.textPrimary)
                    .padding(.vertical, DS.Spacing.sm)
                    .padding(.horizontal, DS.Spacing.md)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                            .fill(DS.Colors.surface3)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open full settings")
            }
        }
        .frame(maxHeight: 320)
    }

    // MARK: - Section

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder _ content: @escaping () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(DS.Colors.textTertiary)
                .padding(.horizontal, DS.Spacing.xs)

            DSCard {
                VStack(spacing: DS.Spacing.xs) {
                    content()
                }
            }
        }
    }

    // MARK: - Rows

    /// A row that opens the main SettingsView window (link-out semantics).
    private func linkRow(_ title: String, systemImage: String) -> some View {
        actionRow(title, systemImage: systemImage, trailing: "arrow.up.right") {
            SettingsWindowController.shared.show(companionManager: companionManager)
        }
    }

    private func actionRow(
        _ title: String,
        systemImage: String,
        trailing: String = "chevron.right",
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                Spacer()
                Image(systemName: trailing)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .padding(.vertical, DS.Spacing.sm)
            .padding(.horizontal, DS.Spacing.md)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}
