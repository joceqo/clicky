//
//  NotchSettingsTab.swift
//  leanring-buddy
//
//  The Notch "Settings" surface: does NOT rebuild settings — it opens the main
//  settings window via the same SettingsWindowController.shared mechanism the
//  menu-bar panel uses.
//

import SwiftUI

struct NotchSettingsTab: View {
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            Text("Settings")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)

            DSCard {
                VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                    Text("Configure your brain and voice providers, models, and permissions.")
                        .font(.system(size: 12))
                        .foregroundColor(DS.Colors.textSecondary)

                    Button {
                        SettingsWindowController.shared.show(companionManager: companionManager)
                    } label: {
                        HStack(spacing: DS.Spacing.sm) {
                            Image(systemName: "gearshape.fill")
                                .font(.system(size: 12, weight: .medium))
                            Text("Open Settings")
                                .font(.system(size: 12, weight: .semibold))
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundColor(DS.Colors.textPrimary)
                        .padding(.vertical, DS.Spacing.sm)
                        .padding(.horizontal, DS.Spacing.md)
                        .background(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                                .fill(DS.Colors.surface3)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open Settings")
                }
            }
        }
    }
}
