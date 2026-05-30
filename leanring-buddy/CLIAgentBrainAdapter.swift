//
//  CLIAgentBrainAdapter.swift
//  leanring-buddy
//
//  BrainClient adapter that drives a local *agent CLI* (Claude Code, OpenCode,
//  Codex, Cursor, …) as a subprocess. The screenshot is written to a temp file
//  and its path is embedded in the prompt so the agent can read it (these CLIs
//  read images by path, not as inline data). stdout is captured and returned.
//
//  Requires the app to be NON-sandboxed (it is: app-sandbox=false) so Process
//  can spawn external binaries.
//
//  Notes / limitations:
//  - MVP is non-streaming: the full stdout is returned at the end (onTextChunk
//    is called once). Per-event streaming (stream-json) can come later.
//  - Vision quality depends on the agent actually reading the image file.
//  - GUI apps don't inherit the shell PATH, so we augment PATH and run via env.
//

import AppKit
import Foundation

@MainActor
final class CLIAgentBrainAdapter: BrainClient {

    /// Unused for CLI agents (the model is chosen by the CLI's own config), but
    /// required by the BrainClient protocol. Kept so the model picker doesn't break.
    var model: String

    /// Bare command name or absolute path, e.g. "claude", "opencode", "/opt/homebrew/bin/codex".
    private let command: String

    /// Argument template. Use `{prompt}` where the composed prompt should go.
    /// e.g. ["-p", "{prompt}", "--output-format", "text", "--dangerously-skip-permissions"]
    private let argsTemplate: [String]

    private var runningProcess: Process?

    init(command: String, argsTemplate: [String], model: String = "") {
        self.command = command
        self.argsTemplate = argsTemplate
        self.model = model
    }

    // MARK: - BrainClient

    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        let result = try await run(images: images, systemPrompt: systemPrompt, userPrompt: userPrompt)
        onTextChunk(result.text)
        return result
    }

    func analyzeImage(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String
    ) async throws -> (text: String, duration: TimeInterval) {
        try await run(images: images, systemPrompt: systemPrompt, userPrompt: userPrompt)
    }

    // MARK: - Core

    private func run(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        userPrompt: String
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = Date()

        let imagePaths = try writeImagesToTemp(images)
        defer { for path in imagePaths { try? FileManager.default.removeItem(atPath: path) } }

        let prompt = composePrompt(systemPrompt: systemPrompt, userPrompt: userPrompt,
                                   imagePaths: imagePaths, labels: images.map(\.label))
        let arguments = argsTemplate.map { $0 == "{prompt}" ? prompt : $0.replacingOccurrences(of: "{prompt}", with: prompt) }

        let output = try await spawn(command: command, arguments: arguments)
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return (text: text, duration: Date().timeIntervalSince(startTime))
    }

    private func composePrompt(systemPrompt: String, userPrompt: String,
                               imagePaths: [String], labels: [String]) -> String {
        var parts: [String] = [systemPrompt, "", userPrompt]
        if !imagePaths.isEmpty {
            parts.append("")
            parts.append("Screenshot(s) to look at (read these image files):")
            for (path, label) in zip(imagePaths, labels) {
                parts.append("- \(path)  (\(label))")
            }
        }
        return parts.joined(separator: "\n")
    }

    private func writeImagesToTemp(_ images: [(data: Data, label: String)]) throws -> [String] {
        let tmpDir = FileManager.default.temporaryDirectory
        var paths: [String] = []
        for (index, image) in images.enumerated() {
            let isPNG = image.data.starts(with: [0x89, 0x50, 0x4E, 0x47])
            let ext = isPNG ? "png" : "jpg"
            let url = tmpDir.appendingPathComponent("joceclicky-screen-\(index).\(ext)")
            try image.data.write(to: url)
            paths.append(url.path)
        }
        return paths
    }

    /// Spawns `command` via /usr/bin/env (so PATH resolution works), with an
    /// augmented PATH covering Homebrew / ~/.local/bin. Drains stdout+stderr to
    /// EOF on a background queue, then resumes. Terminates on task cancellation.
    private func spawn(command: String, arguments: [String]) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + arguments

        var env = ProcessInfo.processInfo.environment
        let extraPaths = "/opt/homebrew/bin:/usr/local/bin:\(NSHomeDirectory())/.local/bin:/usr/bin:/bin"
        env["PATH"] = extraPaths + ":" + (env["PATH"] ?? "")
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let handle = pipe.fileHandleForReading

        runningProcess = process

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try process.run()
                        // readDataToEndOfFile drains continuously until the pipe
                        // closes at process exit — no 64KB buffer deadlock.
                        let data = handle.readDataToEndOfFile()
                        process.waitUntilExit()
                        continuation.resume(returning: String(data: data, encoding: .utf8) ?? "")
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.runningProcess?.terminate()
            }
        }
    }
}
