//
//  AgentRunner.swift
//  leanring-buddy
//
//  Turns the Notch "Agents" tab into a real launcher: the user types a task,
//  picks a brain (Claude Code / OpenCode / Codex / Cursor), and AgentRunner
//  spawns the matching CLI agent as a subprocess, streaming its output live.
//
//  Subprocess pattern mirrors CLIAgentBrainAdapter: spawn via /usr/bin/env so
//  PATH resolution works, augment PATH with Homebrew / ~/.local/bin (GUI apps
//  don't inherit the shell PATH), drain stdout+stderr, terminate on cancel.
//  Difference: this is a pure prompt→text task (no screenshots), and output is
//  streamed *incrementally* via the pipe's readabilityHandler — every chunk is
//  marshalled back to the MainActor before mutating @Published state.
//
//  Safety: agents run in a dedicated workspace dir under Application Support,
//  NOT $HOME, because agents like Claude Code can create/modify files.
//
//  Persistence: the runs history is persisted to JSON in Application Support
//  (agent-runs.json), so history survives relaunch. Live output for a still
//  running process can't survive a relaunch, so any run left in `.running`
//  state when we load is marked `.failed` (its process is gone).
//

import Combine
import Foundation

// MARK: - Brain options

/// A selectable agent "brain" — label + CLI command + argument template.
/// The command/argsTemplate values are sourced verbatim from the
/// BrainProviderSettings CLI presets (claudeCode / openCode / codex /
/// cursorAgent), so we reuse the exact, already-tuned headless flags.
struct AgentBrainOption: Identifiable, Hashable {
    let id: String
    let label: String
    let command: String
    /// Argument template string with a `{prompt}` placeholder. Whitespace-split
    /// into arguments; `{prompt}` becomes a single argument (the typed task).
    let argsTemplate: String

    /// Resolves `argsTemplate` into concrete arguments, substituting the prompt.
    /// Splits on spaces/newlines (matching BrainProviderFactory), then replaces
    /// any `{prompt}` token with the full prompt as one argument.
    func arguments(for prompt: String) -> [String] {
        argsTemplate
            .split(whereSeparator: { $0 == " " || $0 == "\n" })
            .map(String.init)
            .map { $0 == "{prompt}" ? prompt : $0.replacingOccurrences(of: "{prompt}", with: prompt) }
    }

    // Sourced from BrainProviderSettings presets (single source of truth for flags).
    static let claudeCode = AgentBrainOption(
        id: "claude_code",
        label: "Claude Code",
        command: BrainProviderSettings.claudeCode.cliCommand,
        argsTemplate: BrainProviderSettings.claudeCode.cliArgsTemplate
    )
    static let openCode = AgentBrainOption(
        id: "opencode",
        label: "OpenCode",
        command: BrainProviderSettings.openCode.cliCommand,
        argsTemplate: BrainProviderSettings.openCode.cliArgsTemplate
    )
    static let codex = AgentBrainOption(
        id: "codex",
        label: "Codex",
        command: BrainProviderSettings.codex.cliCommand,
        argsTemplate: BrainProviderSettings.codex.cliArgsTemplate
    )
    static let cursor = AgentBrainOption(
        id: "cursor",
        label: "Cursor",
        command: BrainProviderSettings.cursorAgent.cliCommand,
        argsTemplate: BrainProviderSettings.cursorAgent.cliArgsTemplate
    )

    static let all: [AgentBrainOption] = [.claudeCode, .openCode, .codex, .cursor]
}

// MARK: - Runner

@MainActor
final class AgentRunner: ObservableObject {

    /// All runs, newest first. Published so the Agents tab re-renders as output
    /// streams in and statuses flip.
    @Published private(set) var runs: [AgentRun] = []

    /// Live processes keyed by run id, so we can stream/cancel and keep them
    /// retained across UI updates.
    private var processes: [UUID: Process] = [:]

    // MARK: - Workspace + persistence file layout

    /// Dedicated directory agents run in (NOT $HOME). Created on init.
    /// TODO: make this user-pickable later (commercial app has an "Agent Folder"
    /// setting). For now it's a fixed path under Application Support.
    let workspaceDirectory: URL

    private let runsFileURL: URL

    init() {
        let appSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let clickyDirectoryURL = appSupportURL.appendingPathComponent("Clicky")
        workspaceDirectory = clickyDirectoryURL.appendingPathComponent("agent-workspace")
        runsFileURL = clickyDirectoryURL.appendingPathComponent("agent-runs.json")

        try? FileManager.default.createDirectory(
            at: workspaceDirectory,
            withIntermediateDirectories: true
        )

        load()
    }

    // MARK: - Loading

    private func load() {
        guard let data = try? Data(contentsOf: runsFileURL) else {
            runs = []
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var decoded = try? decoder.decode([AgentRun].self, from: data) else {
            runs = []
            return
        }
        // Any run still marked .running from a previous launch is orphaned — its
        // process died with the app. Mark it failed so the UI isn't stuck.
        for index in decoded.indices where decoded[index].status == .running {
            decoded[index].status = .failed
            decoded[index].finishedAt = decoded[index].finishedAt ?? Date()
        }
        decoded.sort { $0.startedAt > $1.startedAt }
        runs = decoded
    }

    // MARK: - Launch

    /// Creates an AgentRun (.running) and spawns the CLI agent as a subprocess in
    /// the workspace dir, streaming stdout+stderr incrementally into the run.
    func launch(brain: AgentBrainOption, prompt: String) {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return }

        let run = AgentRun(
            brainLabel: brain.label,
            command: brain.command,
            prompt: trimmedPrompt,
            workingDirectory: workspaceDirectory.path
        )
        runs.insert(run, at: 0)
        save()

        let runID = run.id
        let arguments = brain.arguments(for: trimmedPrompt)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [brain.command] + arguments
        process.currentDirectoryURL = workspaceDirectory

        var env = ProcessInfo.processInfo.environment
        let extraPaths = "/opt/homebrew/bin:/usr/local/bin:\(NSHomeDirectory())/.local/bin:/usr/bin:/bin"
        env["PATH"] = extraPaths + ":" + (env["PATH"] ?? "")
        process.environment = env

        // Single pipe for stdout+stderr so output is interleaved in order.
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let handle = pipe.fileHandleForReading

        // Stream chunks live. readabilityHandler runs on a background queue, so
        // hop back to the MainActor before mutating @Published state.
        handle.readabilityHandler = { fileHandle in
            let data = fileHandle.availableData
            guard !data.isEmpty,
                  let chunk = String(data: data, encoding: .utf8), !chunk.isEmpty
            else { return }
            Task { @MainActor [weak self] in
                self?.appendOutput(chunk, to: runID)
            }
        }

        // Terminal handler — fires when the process exits.
        process.terminationHandler = { proc in
            let code = proc.terminationStatus
            let reason = proc.terminationReason
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Drain anything still buffered, then detach the handler.
                let remaining = handle.readDataToEndOfFile()
                if !remaining.isEmpty, let tail = String(data: remaining, encoding: .utf8) {
                    self.appendOutput(tail, to: runID)
                }
                handle.readabilityHandler = nil
                self.finish(
                    runID: runID,
                    // Don't override an explicit .cancelled set by cancel().
                    status: reason == .uncaughtSignal ? .cancelled : (code == 0 ? .succeeded : .failed)
                )
            }
        }

        // Retain the process so it keeps running across UI updates.
        processes[runID] = process

        do {
            try process.run()
        } catch {
            handle.readabilityHandler = nil
            appendOutput("Failed to launch \(brain.command): \(error.localizedDescription)\n", to: runID)
            finish(runID: runID, status: .failed)
        }
    }

    // MARK: - Cancel

    /// Terminates the run's process and marks it .cancelled.
    func cancel(_ runID: UUID) {
        guard let process = processes[runID] else { return }
        if process.isRunning {
            process.terminate()
        }
        // terminationHandler will mark it .cancelled (uncaughtSignal), but set it
        // here too in case the process already exited between the guard and now.
        if let index = runs.firstIndex(where: { $0.id == runID }), runs[index].status == .running {
            finish(runID: runID, status: .cancelled)
        }
    }

    // MARK: - Mutations

    private func appendOutput(_ chunk: String, to runID: UUID) {
        guard let index = runs.firstIndex(where: { $0.id == runID }) else { return }
        runs[index].output.append(chunk)
        // Don't persist on every chunk (too chatty); persistence happens on
        // launch and finish. The in-memory @Published copy drives the live UI.
    }

    private func finish(runID: UUID, status: AgentRunStatus) {
        guard let index = runs.firstIndex(where: { $0.id == runID }) else { return }
        // Already terminal — don't downgrade.
        guard runs[index].status == .running else {
            processes[runID] = nil
            return
        }
        runs[index].status = status
        runs[index].finishedAt = Date()
        processes[runID] = nil
        save()
    }

    // MARK: - Saving

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(runs) else { return }
        try? data.write(to: runsFileURL, options: .atomic)
    }
}
