//
//  NotchHomeTab.swift
//  leanring-buddy
//
//  The Notch "Home" surface: a status dot, a short summary of the three required
//  permissions read live from CompanionManager, and the push-to-talk hint.
//  Reuses StatusBadge / DSCard from Components.swift.
//

import SwiftUI

struct NotchHomeTab: View {
    @ObservedObject var companionManager: CompanionManager

    private var overallStatus: StatusBadge.Status {
        companionManager.allPermissionsGranted ? .connected : .warning
    }

    private var overallLabel: String {
        companionManager.allPermissionsGranted ? "Ready" : "Setup needed"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            HStack {
                Text("Status")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                Spacer()
                StatusBadge(status: overallStatus, label: overallLabel)
            }

            DSCard {
                VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                    Text("Permissions")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textTertiary)

                    permissionRow(
                        "Accessibility",
                        granted: companionManager.hasAccessibilityPermission
                    )
                    permissionRow(
                        "Screen Recording",
                        granted: companionManager.hasScreenRecordingPermission
                    )
                    permissionRow(
                        "Microphone",
                        granted: companionManager.hasMicrophonePermission
                    )
                }
            }

            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.accentText)
                Text("Hold Control+Option to talk.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }
        }
    }

    private func permissionRow(_ label: String, granted: Bool) -> some View {
        HStack(spacing: DS.Spacing.sm) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(granted ? DS.Colors.success : DS.Colors.warning)
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textPrimary)
            Spacer()
            Text(granted ? "Granted" : "Needed")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(granted ? DS.Colors.success : DS.Colors.textTertiary)
        }
    }
}
