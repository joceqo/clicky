//
//  AgentRun.swift
//  leanring-buddy
//
//  Model for a single agent launch — the user types a task, picks a brain
//  (Claude Code / OpenCode / Codex / Cursor), and a CLI agent runs as a
//  subprocess. One AgentRun captures everything we know about that run:
//  which brain, the exact command, the prompt, live-accumulated output, and
//  the lifecycle status.
//
//  Codable so AgentRunner can persist the history to JSON in Application
//  Support — the same pattern Note/NotesStore use.
//

import Foundation

/// Lifecycle of a single agent run.
enum AgentRunStatus: String, Codable {
    case running
    case succeeded
    case failed
    case cancelled

    var label: String {
        switch self {
        case .running:   return "Running"
        case .succeeded: return "Succeeded"
        case .failed:    return "Failed"
        case .cancelled: return "Cancelled"
        }
    }
}

struct AgentRun: Identifiable, Codable, Equatable {
    let id: UUID
    /// Human label for the chosen brain, e.g. "Claude Code".
    let brainLabel: String
    /// The resolved CLI command, e.g. "claude".
    let command: String
    /// The task the user typed.
    let prompt: String
    /// Live lifecycle status — flips from .running to a terminal state on exit.
    var status: AgentRunStatus
    /// Accumulated stdout+stderr, appended incrementally as the agent emits it.
    var output: String
    let startedAt: Date
    /// Set when the process exits (or is cancelled); nil while running.
    var finishedAt: Date?
    /// Directory the agent ran in (the dedicated workspace, not $HOME).
    let workingDirectory: String

    init(
        id: UUID = UUID(),
        brainLabel: String,
        command: String,
        prompt: String,
        status: AgentRunStatus = .running,
        output: String = "",
        startedAt: Date = Date(),
        finishedAt: Date? = nil,
        workingDirectory: String
    ) {
        self.id = id
        self.brainLabel = brainLabel
        self.command = command
        self.prompt = prompt
        self.status = status
        self.output = output
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.workingDirectory = workingDirectory
    }

    /// A single-line preview of the prompt for list rows.
    var promptPreview: String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let oneLine = trimmed.replacingOccurrences(of: "\n", with: " ")
        guard oneLine.count > 80 else { return oneLine }
        return String(oneLine.prefix(80)) + "…"
    }
}
