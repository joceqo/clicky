//
//  DesignSystemGallery.swift
//  leanring-buddy
//
//  A visual catalog of the design system — color tokens, radii, and every
//  button style in its resting state. Not shipped in the UI; it exists purely
//  as a SwiftUI #Preview so the DS can be audited at a glance and kept honest
//  as tokens evolve. Open this file in Xcode and use the canvas (⌥⌘↩).
//

import SwiftUI

// MARK: - Swatch

private struct Swatch: View {
    let name: String
    let color: Color
    /// Optional hex caption shown under the name.
    var hex: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium)
                .fill(color)
                .frame(height: 44)
                .overlay(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 1)
                )
            Text(name)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textPrimary)
            if let hex {
                Text(hex)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(DS.Colors.textTertiary)
            }
        }
    }
}

private struct SwatchGrid: View {
    let title: String
    let items: [(String, Color, String?)]

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Colors.textTertiary)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                ForEach(items, id: \.0) { item in
                    Swatch(name: item.0, color: item.1, hex: item.2)
                }
            }
        }
    }
}

// MARK: - Button Gallery

private struct ButtonGallery: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("BUTTON STYLES")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Colors.textTertiary)

            Button("Primary — Let's go") {}
                .dsPrimaryButtonStyle(isFullWidth: false)

            Button("Secondary — Open link") {}
                .dsSecondaryButtonStyle(isFullWidth: false)

            Button("Outlined — Copy prompt") {}
                .dsOutlinedButtonStyle(isFullWidth: false)

            Button("Tertiary — Sidebar item") {}
                .dsTertiaryButtonStyle()

            Button("Text — Skip") {}
                .dsTextButtonStyle()

            Button("Destructive — Close session") {}
                .dsDestructiveButtonStyle()

            HStack(spacing: 12) {
                Button { } label: { Image(systemName: "xmark") }
                    .dsIconButtonStyle(tooltip: "Close")
                Button { } label: { Image(systemName: "paperplane.fill") }
                    .dsIconButtonStyle(tooltip: "Send")
                Button { } label: { Image(systemName: "trash") }
                    .dsIconButtonStyle(isDestructiveOnHover: true, tooltip: "Delete")
            }
        }
    }
}

// MARK: - Gallery

struct DesignSystemGallery: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("Design System")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(DS.Colors.textPrimary)

                SwatchGrid(title: "Backgrounds", items: [
                    ("background", DS.Colors.background, "#101211"),
                    ("surface1", DS.Colors.surface1, "#171918"),
                    ("surface2", DS.Colors.surface2, "#202221"),
                    ("surface3", DS.Colors.surface3, "#272A29"),
                    ("surface4", DS.Colors.surface4, "#2E3130")
                ])

                SwatchGrid(title: "Borders & Text", items: [
                    ("borderSubtle", DS.Colors.borderSubtle, "#373B39"),
                    ("borderStrong", DS.Colors.borderStrong, "#444947"),
                    ("textPrimary", DS.Colors.textPrimary, "#ECEEED"),
                    ("textSecondary", DS.Colors.textSecondary, "#ADB5B2"),
                    ("textTertiary", DS.Colors.textTertiary, "#6B736F")
                ])

                SwatchGrid(title: "Blue Scale", items: [
                    ("blue400", DS.Colors.blue400, "#60a5fa"),
                    ("blue500", DS.Colors.blue500, "#3b82f6"),
                    ("accent / blue600", DS.Colors.accent, "#2563eb"),
                    ("accentHover / 700", DS.Colors.accentHover, "#1d4ed8"),
                    ("blue800", DS.Colors.blue800, "#1e40af"),
                    ("blue900", DS.Colors.blue900, "#1e3a8a")
                ])

                SwatchGrid(title: "Semantic", items: [
                    ("destructive", DS.Colors.destructive, "#E5484D"),
                    ("success", DS.Colors.success, "#34D399"),
                    ("warning", DS.Colors.warning, "#FFB224"),
                    ("info", DS.Colors.info, "#70B8FF"),
                    ("codeText", DS.Colors.codeText, "#9DC2FF")
                ])

                SwatchGrid(title: "Overlay / Gradient / Waveform", items: [
                    ("overlayCursorBlue", DS.Colors.overlayCursorBlue, "#3380FF"),
                    ("gradientPurple", DS.Colors.floatingGradientPurple, "#8F46EB"),
                    ("gradientPink", DS.Colors.floatingGradientPink, "#E84D9E"),
                    ("gradientOrange", DS.Colors.floatingGradientOrange, "#FF8C33"),
                    ("waveformLeading", BuddyComposerVisualStyle.waveformLeadingColor, "#F3FBFF"),
                    ("waveformTrailing", BuddyComposerVisualStyle.waveformTrailingColor, "#8FD2FF"),
                    ("waveformGlow", BuddyComposerVisualStyle.waveformGlowColor, "#AEE3FF")
                ])

                ButtonGallery()
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(DS.Colors.background)
    }
}

#Preview("Design System") {
    DesignSystemGallery()
        .frame(width: 720, height: 900)
}
