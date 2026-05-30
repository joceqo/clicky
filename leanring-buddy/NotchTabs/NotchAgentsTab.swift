//
//  NotchAgentsTab.swift
//  leanring-buddy
//
//  The Notch "Agents" surface. Surfaces REAL agent/brain state — no fake data:
//    • Current brain — provider display name + model, with small capability
//      badges, read from CompanionManager.providerStore.brain.
//    • Persistent agent server — running status, baseURL/port from
//      OpenCodeServerManager.shared. There is no safe-to-call "start" entry
//      point that doesn't require a binary path + an awaited launch, so this is
//      status-only (it reflects whether the server has been spawned by a turn).
//    • Recent activity — the last few exchanges from
//      CompanionManager.recentExchanges(), with an "Open chat" action; clean
//      empty state when there's nothing yet.
//
//  All chrome uses DSCard / StatusBadge / IndicatorChip.
//

import SwiftUI

struct NotchAgentsTab: View {
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.md) {
                Text("Agents")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)

                brainCard
                serverCard
                activityCard
            }
        }
        .frame(maxHeight: 320)
    }

    // MARK: - Current Brain

    private var brainCard: some View {
        DSCard {
            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                sectionLabel("Brain")

                Text(companionManager.currentBrainProviderName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                if let model = companionManager.currentBrainModel {
                    HStack(spacing: 6) {
                        Image(systemName: "cube")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(DS.Colors.textTertiary)
                        Text(model)
                            .font(.system(size: 12))
                            .foregroundColor(DS.Colors.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                } else {
                    Text("No model selector")
                        .font(.system(size: 12))
                        .foregroundColor(DS.Colors.textTertiary)
                }

                HStack(spacing: DS.Spacing.sm) {
                    IndicatorChip(
                        systemImage: companionManager.currentBrainHasVision ? "eye" : "eye.slash",
                        text: companionManager.currentBrainHasVision ? "Vision" : "Text-only",
                        tint: companionManager.currentBrainHasVision ? DS.Colors.success : DS.Colors.textTertiary
                    )
                }
            }
        }
    }

    // MARK: - Agent Server

    private var serverCard: some View {
        let manager = OpenCodeServerManager.shared
        let isRunning = manager.isRunning
        let isStarting = manager.isStarting

        return DSCard {
            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                HStack {
                    sectionLabel("Agent server")
                    Spacer()
                    StatusBadge(
                        status: isRunning ? .connected : (isStarting ? .working : .idle),
                        label: isRunning ? "Running" : (isStarting ? "Starting…" : "Not started")
                    )
                }

                Text("OpenCode (persistent server)")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)

                if let baseURL = manager.baseURL {
                    detailRow(icon: "network", text: baseURL.absoluteString)
                    if let port = baseURL.port {
                        detailRow(icon: "number", text: "Port \(port)")
                    }
                } else {
                    Text("Starts on the first agent turn (OpenCode brain). No active server.")
                        .font(.system(size: 12))
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Recent Activity

    private var activityCard: some View {
        let exchanges = companionManager.recentExchanges()

        return DSCard {
            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                HStack {
                    sectionLabel("Recent activity")
                    Spacer()
                    Button {
                        companionManager.openChatWindow()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "bubble.left.and.bubble.right")
                                .font(.system(size: 11, weight: .semibold))
                            Text("Open chat")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundColor(DS.Colors.accentText)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open chat")
                }

                if exchanges.isEmpty {
                    Text("No activity yet. Talk to Clicky or open a chat to get started.")
                        .font(.system(size: 12))
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                        ForEach(exchanges.reversed()) { exchange in
                            activityRow(exchange)
                        }
                    }
                }
            }
        }
    }

    private func activityRow(_ exchange: CompanionManager.RecentExchange) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "person.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
                    .padding(.top, 1)
                Text(preview(exchange.userTranscript))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(2)
            }
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.accentText)
                    .padding(.top, 1)
                Text(preview(exchange.assistantResponse))
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, DS.Spacing.xs)
        .padding(.horizontal, DS.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .fill(DS.Colors.surface3)
        )
    }

    // MARK: - Helpers

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(DS.Colors.textTertiary)
            .tracking(0.5)
    }

    private func detailRow(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    /// Trims and shortens a transcript/response to a single readable preview line.
    private func preview(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 140 else { return trimmed }
        return String(trimmed.prefix(140)) + "…"
    }
}
