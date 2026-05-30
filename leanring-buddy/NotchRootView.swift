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
            notchSilhouette

            tabBar
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

    // MARK: - Notch silhouette / glow

    /// A small cosmetic accent evoking the hardware notch the panel hangs from:
    /// a rounded black bump with a soft accent glow. Pure SwiftUI, no private APIs.
    private var notchSilhouette: some View {
        ZStack {
            Capsule()
                .fill(DS.Colors.accent.opacity(0.20))
                .frame(width: 90, height: 8)
                .blur(radius: 8)
                .offset(y: 2)

            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.black)
                .frame(width: 64, height: 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, DS.Spacing.sm)
        .accessibilityHidden(true)
    }

    // MARK: - Tab bar

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(NotchTab.allCases) { tab in
                tabButton(tab)
            }
        }
    }

    private func tabButton(_ tab: NotchTab) -> some View {
        let isSelected = selectedTab == tab
        return Button {
            selectedTab = tab
        } label: {
            VStack(spacing: 3) {
                Image(systemName: tab.systemImage)
                    .font(.system(size: 13, weight: .medium))
                Text(tab.rawValue)
                    .font(.system(size: 9, weight: .medium))
            }
            .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textTertiary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(isSelected ? DS.Colors.surface3 : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.rawValue)
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
