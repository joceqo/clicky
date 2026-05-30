//
//  NotchRootView.swift
//  leanring-buddy
//
//  The SwiftUI shell hosted by NotchWindowManager: a top tab bar with 6 tabs
//  and a content area that switches on the selected tab. Dark, rounded,
//  notch-flavored chrome built on the DS tokens (DS.Colors / DS.Spacing /
//  DS.CornerRadius) and the shared building blocks in Components.swift.
//
//  Structure mirrors the SHAPE of the commercial Clicky Notch
//  (tabBar + content + a small silhouette/glow accent under the notch), but the
//  layout and code are our own. The 6 tabs are Home / Threads / Notes / Crons /
//  Agents / Settings. Home / Threads / Settings are live; Notes / Crons / Agents
//  are intentional "coming soon" stubs.
//

import SwiftUI

/// The six top-level surfaces of the Notch shell.
enum NotchTab: String, CaseIterable, Identifiable {
    case home = "Home"
    case threads = "Threads"
    case notes = "Notes"
    case crons = "Crons"
    case agents = "Agents"
    case settings = "Settings"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .home:     return "house.fill"
        case .threads:  return "bubble.left.and.bubble.right.fill"
        case .notes:    return "note.text"
        case .crons:    return "clock.arrow.circlepath"
        case .agents:   return "cpu"
        case .settings: return "gearshape.fill"
        }
    }
}

struct NotchRootView: View {
    @ObservedObject var companionManager: CompanionManager
    @State private var selectedTab: NotchTab = .home

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, DS.Spacing.sm)
                .padding(.top, DS.Spacing.sm)

            Divider()
                .background(DS.Colors.borderSubtle)
                .padding(.top, DS.Spacing.sm)

            content
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(DS.Spacing.lg)
        }
        .frame(width: 420)
        .background(DS.Colors.background)
        .clickyPanelBackground(cornerRadius: DS.CornerRadius.extraLarge)
    }

    // MARK: - Header (continuous buddy glyph + compact tab bar)

    /// The expanded header: the same buddy triangle that lives in the compact
    /// pill (so the morph reads as continuous), the primary tabs as small
    /// icon+label pills, and a trailing gear that selects Settings — mirroring
    /// the real Clicky's "Home · Agents · ⚙" top bar.
    private var header: some View {
        HStack(spacing: DS.Spacing.sm) {
            // Continuous buddy glyph — same triangle as the compact pill.
            NotchBuddyGlyph(width: 12, height: 10)
                .padding(.trailing, 2)

            tabBar

            Spacer(minLength: 0)

            // Trailing gear affordance → Settings tab (like 4011's ⚙).
            gearButton
        }
    }

    // MARK: - Tab bar

    /// The primary tabs (everything except Settings, which lives in the trailing
    /// gear). Compact icon+label pills with a rounded highlight on the selected
    /// one — matching 4011 where Home is highlighted.
    private var primaryTabs: [NotchTab] {
        NotchTab.allCases.filter { $0 != .settings }
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(primaryTabs) { tab in
                tabButton(tab)
            }
        }
    }

    private func tabButton(_ tab: NotchTab) -> some View {
        let isSelected = selectedTab == tab
        return Button {
            selectedTab = tab
        } label: {
            HStack(spacing: 4) {
                Image(systemName: tab.systemImage)
                    .font(.system(size: 11, weight: .semibold))
                // Only the selected tab shows its label (compact pill, like 4011).
                if isSelected {
                    Text(tab.rawValue)
                        .font(.system(size: 11, weight: .semibold))
                        .fixedSize()
                }
            }
            .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textTertiary)
            .padding(.vertical, 5)
            .padding(.horizontal, isSelected ? 10 : 7)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.pill, style: .continuous)
                    .fill(isSelected ? DS.Colors.surface3 : Color.clear)
            )
            // Whole pill is hit-testable (avoids tap-misses on the gaps).
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.rawValue)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var gearButton: some View {
        let isSelected = selectedTab == .settings
        return Button {
            selectedTab = .settings
        } label: {
            Image(systemName: NotchTab.settings.systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                .padding(6)
                .background(
                    Circle().fill(isSelected ? DS.Colors.surface3 : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(NotchTab.settings.rawValue)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch selectedTab {
        case .home:
            NotchHomeTab(companionManager: companionManager)
        case .threads:
            NotchThreadsTab(companionManager: companionManager)
        case .notes:
            NotchComingSoonTab(
                systemImage: "note.text",
                title: "Notes",
                line: "A place for your wiki articles and saved notes. Coming soon."
            )
        case .crons:
            NotchComingSoonTab(
                systemImage: "clock.arrow.circlepath",
                title: "Crons",
                line: "Scheduled agents that run on a timer. Coming soon."
            )
        case .agents:
            NotchComingSoonTab(
                systemImage: "cpu",
                title: "Agents",
                line: "Background agent tasks and their activity. Coming soon."
            )
        case .settings:
            NotchSettingsTab(companionManager: companionManager)
        }
    }
}
