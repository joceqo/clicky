//
//  NotchHomeTab.swift
//  leanring-buddy
//
//  The Notch "Home" surface, modeled on the commercial Clicky Home tab (4011):
//  a push-to-talk hint (with the "Control twice for text mode" line), a
//  "Cursor color" row of triangle swatches, an "Active integrations" row, and a
//  Dock/Undock button. Permissions are kept as a compact status block so the
//  setup state is still glanceable. Reuses StatusBadge / DSCard from
//  Components.swift.
//

import SwiftUI

struct NotchHomeTab: View {
    @ObservedObject var companionManager: CompanionManager

    /// LIVE cursor color — shared with OverlayWindow's BlueCursorView and the
    /// notch glyph via the same @AppStorage key.
    @AppStorage(buddyCursorColorKey) private var cursorColorRaw: String = BuddyCursorColor.blue.rawValue

    /// Dock-visibility preference — shared with the Settings tab's toggle.
    @AppStorage(showInDockKey) private var showInDock: Bool = false

    private var overallStatus: StatusBadge.Status {
        companionManager.allPermissionsGranted ? .connected : .warning
    }

    private var overallLabel: String {
        companionManager.allPermissionsGranted ? "Ready" : "Setup needed"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            // Push-to-talk hint (two lines, matching 4011).
            talkHint

            // Cursor color swatches.
            cursorColorRow

            // Active integrations (stub).
            integrationsRow

            // Compact permissions status.
            DSCard {
                VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                    HStack {
                        Text("Permissions")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Colors.textTertiary)
                        Spacer()
                        StatusBadge(status: overallStatus, label: overallLabel)
                    }

                    permissionRow("Accessibility", granted: companionManager.hasAccessibilityPermission)
                    permissionRow("Screen Recording", granted: companionManager.hasScreenRecordingPermission)
                    permissionRow("Microphone", granted: companionManager.hasMicrophonePermission)
                }
            }

            // Dock / Undock button.
            dockButton
        }
    }

    // MARK: - Talk hint

    private var talkHint: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.accentText)
                Text("Hold Control+Option to talk.")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
            }
            // NOTE: text mode itself is not implemented yet — this line mirrors
            // the real Clicky copy so the affordance is discoverable.
            Text("Also, you can press Control twice to enter text mode.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
        }
    }

    // MARK: - Cursor color

    private var cursorColorRow: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Text("Cursor color")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Colors.textTertiary)

            HStack(spacing: DS.Spacing.sm) {
                ForEach(BuddyCursorColor.allCases) { swatch in
                    cursorSwatch(swatch)
                }
            }
        }
    }

    private func cursorSwatch(_ swatch: BuddyCursorColor) -> some View {
        let isSelected = cursorColorRaw == swatch.rawValue
        return Button {
            cursorColorRaw = swatch.rawValue
        } label: {
            NotchTriangle()
                .fill(swatch.color)
                .frame(width: 18, height: 16)
                .frame(width: 56, height: 38)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .fill(DS.Colors.surface2)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .stroke(isSelected ? swatch.color : DS.Colors.borderSubtle,
                                lineWidth: isSelected ? 2 : 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(swatch.rawValue.capitalized) cursor")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: - Active integrations (stub)

    private var integrationsRow: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Text("Active integrations")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Colors.textTertiary)

            DSCard {
                HStack(spacing: DS.Spacing.sm) {
                    Text("No integrations yet")
                        .font(.system(size: 12))
                        .foregroundColor(DS.Colors.textTertiary)
                    Spacer()
                    // STUB: non-functional "+" — integrations have no backend yet.
                    Button {
                        // TODO: open the integrations picker once integrations exist.
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(DS.Colors.textSecondary)
                            .frame(width: 24, height: 24)
                            .background(
                                RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                                    .fill(DS.Colors.surface3)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add integration")
                }
            }
        }
    }

    // MARK: - Dock / Undock

    private var dockButton: some View {
        Button {
            showInDock.toggle()
            DockVisibility.apply(showInDock: showInDock)
        } label: {
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: showInDock ? "dock.rectangle" : "menubar.rectangle")
                    .font(.system(size: 12, weight: .semibold))
                Text(showInDock ? "Undock Clicky" : "Dock Clicky")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, DS.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(DS.Colors.success)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(showInDock ? "Undock Clicky" : "Dock Clicky")
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
