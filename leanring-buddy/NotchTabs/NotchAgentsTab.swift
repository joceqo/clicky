//
//  NotchAgentsTab.swift
//  leanring-buddy
//
//  The Notch "Agents" surface — now a real AGENT LAUNCHER.
//
//    • Launch an agent — type a task, pick a brain (Claude Code / OpenCode /
//      Codex / Cursor), hit Run. The chosen CLI agent runs as a subprocess
//      (AgentRunner) in a dedicated workspace dir, output streamed live.
//    • Runs — each run shows brain + prompt preview + a StatusBadge; tapping
//      opens a detail view with the full live-streaming output and a Cancel
//      button while running.
//    • Brain / server status (kept, compacted) — current brain provider/model
//      and the persistent OpenCode server state.
//
//  All chrome uses DSCard / StatusBadge / IndicatorChip.
//

import SwiftUI

struct NotchAgentsTab: View {
    @ObservedObject var companionManager: CompanionManager

    /// The launcher state lives on CompanionManager so runs survive tab switches.
    private var runner: AgentRunner { companionManager.agentRunner }

    @State private var prompt: String = ""
    @State private var selectedBrain: AgentBrainOption = .claudeCode
    @State private var selectedRunID: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.md) {
                Text("Agents")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)

                launcherCard
                runsCard
                brainCard
                serverCard
            }
        }
        .frame(maxHeight: 420)
        .sheet(item: selectedRunBinding) { run in
            AgentRunDetailView(
                runID: run.id,
                runner: runner,
                onClose: { selectedRunID = nil }
            )
        }
    }

    // Bridges the optional selected id to a `sheet(item:)` binding.
    private var selectedRunBinding: Binding<AgentRun?> {
        Binding(
            get: { runner.runs.first { $0.id == selectedRunID } },
            set: { selectedRunID = $0?.id }
        )
    }

    // MARK: - Launcher

    private var launcherCard: some View {
        DSCard {
            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                sectionLabel("Launch an agent")

                TextEditor(text: $prompt)
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textPrimary)
                    .scrollContentBackground(.hidden)
                    .frame(height: 64)
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                            .fill(DS.Colors.surface3)
                    )
                    .overlay(alignment: .topLeading) {
                        if prompt.isEmpty {
                            Text("Describe the task…")
                                .font(.system(size: 12))
                                .foregroundColor(DS.Colors.textTertiary)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 14)
                                .allowsHitTesting(false)
                        }
                    }

                HStack(spacing: DS.Spacing.sm) {
                    Picker("Brain", selection: $selectedBrain) {
                        ForEach(AgentBrainOption.all) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 160)

                    Spacer()

                    Button {
                        runner.launch(brain: selectedBrain, prompt: prompt)
                        prompt = ""
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 10, weight: .bold))
                            Text("Run")
                                .font(.system(size: 12, weight: .semibold))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                detailRow(
                    icon: "folder",
                    text: "Workspace: \(runner.workspaceDirectory.path)"
                )
            }
        }
    }

    // MARK: - Runs

    private var runsCard: some View {
        DSCard {
            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                sectionLabel("Runs")

                if runner.runs.isEmpty {
                    Text("No runs yet. Type a task above and hit Run.")
                        .font(.system(size: 12))
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                        ForEach(runner.runs) { run in
                            Button { selectedRunID = run.id } label: {
                                runRow(run)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private func runRow(_ run: AgentRun) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: "cpu")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(DS.Colors.accentText)
                    Text(run.brainLabel)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                }
                Text(run.promptPreview)
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            Spacer()
            statusBadge(for: run.status)
        }
        .padding(.vertical, DS.Spacing.xs)
        .padding(.horizontal, DS.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .fill(DS.Colors.surface3)
        )
        .contentShape(Rectangle())
    }

    // MARK: - Current Brain (compact)

    private var brainCard: some View {
        DSCard {
            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                sectionLabel("Brain")
                Text(companionManager.currentBrainProviderName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let model = companionManager.currentBrainModel {
                    detailRow(icon: "cube", text: model)
                }
            }
        }
    }

    // MARK: - Agent Server (compact)

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
                if let baseURL = manager.baseURL {
                    detailRow(icon: "network", text: baseURL.absoluteString)
                } else {
                    Text("Starts on the first agent turn (OpenCode brain).")
                        .font(.system(size: 12))
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Helpers

    private func statusBadge(for status: AgentRunStatus) -> some View {
        let mapped: StatusBadge.Status
        switch status {
        case .running:   mapped = .working
        case .succeeded: mapped = .connected
        case .failed:    mapped = .error
        case .cancelled: mapped = .warning
        }
        return HStack(spacing: 4) {
            if status == .running {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.7)
            }
            StatusBadge(status: mapped, label: status.label)
        }
    }

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
}

// MARK: - Run Detail

/// Detail view for a single run — full live-streaming output (monospaced,
/// scrollable, auto-scrolls to bottom) with a Cancel button while running.
private struct AgentRunDetailView: View {
    let runID: UUID
    @ObservedObject var runner: AgentRunner
    let onClose: () -> Void

    private var run: AgentRun? { runner.runs.first { $0.id == runID } }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            if let run {
                header(run)
                outputView(run)
                footer(run)
            } else {
                Text("Run not found.")
                    .foregroundColor(DS.Colors.textTertiary)
            }
        }
        .padding(DS.Spacing.lg)
        .frame(width: 520, height: 460)
        .background(DS.Colors.background)
    }

    private func header(_ run: AgentRun) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "cpu")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.accentText)
                    Text(run.brainLabel)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text(run.command)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                Text(run.prompt)
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            StatusBadge(status: badgeStatus(run.status), label: run.status.label)
        }
    }

    private func outputView(_ run: AgentRun) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(run.output.isEmpty ? "Waiting for output…" : run.output)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(run.output.isEmpty ? DS.Colors.textTertiary : DS.Colors.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DS.Spacing.sm)
                    .id("output-bottom-anchor")
            }
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(DS.Colors.surface2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 1)
            )
            .frame(maxHeight: .infinity)
            .onChange(of: run.output) { _, _ in
                withAnimation(.linear(duration: 0.1)) {
                    proxy.scrollTo("output-bottom-anchor", anchor: .bottom)
                }
            }
        }
    }

    private func footer(_ run: AgentRun) -> some View {
        HStack {
            Text("Workspace: \(run.workingDirectory)")
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if run.status == .running {
                Button(role: .destructive) {
                    runner.cancel(run.id)
                } label: {
                    Text("Cancel")
                        .font(.system(size: 12, weight: .semibold))
                }
                .controlSize(.small)
            }
            Button("Close", action: onClose)
                .controlSize(.small)
        }
    }

    private func badgeStatus(_ status: AgentRunStatus) -> StatusBadge.Status {
        switch status {
        case .running:   return .working
        case .succeeded: return .connected
        case .failed:    return .error
        case .cancelled: return .warning
        }
    }
}
