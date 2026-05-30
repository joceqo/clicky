//
//  NotchComingSoonTab.swift
//  leanring-buddy
//
//  A clean, intentional "coming soon" stub surface used by the Notes / Crons /
//  Agents tabs, which have no backend yet. DSCard + icon + one line so the tab
//  looks deliberate, not broken.
//

import SwiftUI

struct NotchComingSoonTab: View {
    let systemImage: String
    let title: String
    let line: String

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)

            DSCard {
                VStack(spacing: DS.Spacing.md) {
                    Image(systemName: systemImage)
                        .font(.system(size: 28, weight: .light))
                        .foregroundColor(DS.Colors.textTertiary)

                    Text("Coming soon")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(DS.Colors.textSecondary)

                    Text(line)
                        .font(.system(size: 12))
                        .foregroundColor(DS.Colors.textTertiary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, DS.Spacing.md)
            }
        }
    }
}
