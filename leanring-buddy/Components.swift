//
//  Components.swift
//  leanring-buddy
//
//  Reusable presentational components built on the DS tokens. These mirror the
//  small building blocks the commercial app composes its surfaces from
//  (panel chrome, status badge, indicator chip, voice pill, card) but kept
//  minimal and dependency-free so any view can reuse them. Layout is our own;
//  only the design tokens are shared with DesignSystem.swift.
//

import SwiftUI

// MARK: - Panel Background

/// The standard floating-panel chrome: elevated surface, hairline border, soft
/// drop shadow. Wrap any panel content with `.clickyPanelBackground()`.
struct ClickyPanelBackground: ViewModifier {
    var cornerRadius: CGFloat = DS.CornerRadius.extraLarge
    var fill: Color = DS.Colors.surface1

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.42), radius: 24, x: 0, y: 12)
            .shadow(color: Color.black.opacity(0.20), radius: 4, x: 0, y: 2)
    }
}

extension View {
    func clickyPanelBackground(
        cornerRadius: CGFloat = DS.CornerRadius.extraLarge,
        fill: Color = DS.Colors.surface1
    ) -> some View {
        modifier(ClickyPanelBackground(cornerRadius: cornerRadius, fill: fill))
    }
}

// MARK: - Card

/// A simple elevated container with padding — the default surface for grouped content.
struct DSCard<Content: View>: View {
    var padding: CGFloat = DS.Spacing.lg
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                    .fill(DS.Colors.surface2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 1)
            )
    }
}

// MARK: - Status Badge

/// A small pill conveying a status. Mirrors `AgentIntegrationStatusBadge`.
struct StatusBadge: View {
    enum Status {
        case idle, connected, working, warning, error

        var color: Color {
            switch self {
            case .idle:      return DS.Colors.textTertiary
            case .connected: return DS.Colors.success
            case .working:   return DS.Colors.accentText
            case .warning:   return DS.Colors.warning
            case .error:     return DS.Colors.destructiveText
            }
        }
    }

    let status: Status
    let label: String

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(status.color)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(status.color.opacity(0.12))
        )
        .overlay(
            Capsule().stroke(status.color.opacity(0.25), lineWidth: 1)
        )
    }
}

// MARK: - Indicator Chip

/// An icon + label chip for transient state hints. Mirrors `HandoffIndicatorChipView`.
struct IndicatorChip: View {
    let systemImage: String
    let text: String
    var tint: Color = DS.Colors.accentText

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(tint)
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textPrimary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(DS.Colors.surface3))
        .overlay(Capsule().stroke(DS.Colors.borderSubtle, lineWidth: 1))
    }
}

// MARK: - Voice Pill

/// The push-to-talk / speaking pill. Mirrors `HandoffVoiceStopPillView`: shows a
/// listening or speaking state with an animated accent dot, and a stop affordance.
struct VoiceStopPill: View {
    enum Mode { case listening, speaking }

    let mode: Mode
    var onStop: () -> Void = {}

    @State private var pulse = false

    private var tint: Color {
        mode == .listening ? DS.Colors.overlayCursorBlue : DS.Colors.success
    }
    private var label: String {
        mode == .listening ? "Listening…" : "Speaking…"
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
                .scaleEffect(pulse ? 1.4 : 0.8)
                .opacity(pulse ? 1.0 : 0.5)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)

            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(DS.Colors.textPrimary)

            Button(action: onStop) {
                Image(systemName: "stop.fill")
            }
            .dsIconButtonStyle(size: 22, tooltip: "Stop")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Capsule().fill(DS.Colors.surface2))
        .overlay(Capsule().stroke(tint.opacity(0.35), lineWidth: 1))
        .shadow(color: tint.opacity(0.25), radius: 12)
        .onAppear { pulse = true }
    }
}

// MARK: - Preview

#Preview("Components") {
    VStack(alignment: .leading, spacing: 20) {
        DSCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Panel & Card")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                HStack(spacing: 8) {
                    StatusBadge(status: .connected, label: "Connected")
                    StatusBadge(status: .working, label: "Working")
                    StatusBadge(status: .error, label: "Error")
                }
                HStack(spacing: 8) {
                    IndicatorChip(systemImage: "hand.point.up.left.fill", text: "Pointing")
                    IndicatorChip(systemImage: "sparkles", text: "Thinking", tint: DS.Colors.info)
                }
            }
        }

        VoiceStopPill(mode: .listening)
        VoiceStopPill(mode: .speaking)
    }
    .padding(28)
    .frame(width: 460)
    .background(DS.Colors.background)
    .clickyPanelBackground()
    .padding(40)
}
