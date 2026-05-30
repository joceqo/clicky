//
//  OpenCodeServerManager.swift
//  leanring-buddy
//
//  Owns the lifecycle of a single long-lived `opencode serve` HTTP server so the
//  agent brain doesn't pay a cold-start (process spawn + model warmup) on every
//  voice turn. The server is spawned once, kept alive across turns, and reused by
//  `OpenCodeServerBrainClient`. This is "Couche 1" toward a persistent agent brain.
//
//  Why a server instead of spawn-per-turn (see CLIAgentBrainAdapter):
//    `opencode run <prompt>` boots the whole runtime every call (~seconds of cold
//    start). `opencode serve` boots once and answers many prompts over HTTP, and a
//    reused *session* keeps multi-turn context server-side.
//
//  Discovered OpenCode server API (from the opencode SDK source, dev branch —
//  packages/sdk/js/src/gen/{types,sdk}.gen.ts; could not run the binary here):
//    - Launch:        `opencode serve --hostname 127.0.0.1 --port <n> --print-logs`
//                     (default port 4096; we pass an explicit free port we pick
//                     ourselves so we never have to scrape the port from logs).
//    - Create session: POST /session            body { title? }     → Session { id, ... }
//    - Send a prompt:  POST /session/{id}/message
//                       body { model?: { providerID, modelID }, system?, parts: [...] }
//                       → { info: Message, parts: [Part] }   (blocks until complete)
//    - OpenAPI spec:   GET  /doc
//  Auth is only required when OPENCODE_SERVER_PASSWORD is set; we don't set it.
//
//  Requires the app to be NON-sandboxed (it is: app-sandbox=false) so Process can
//  spawn external binaries. GUI apps don't inherit the shell PATH, so we augment
//  PATH and run via /usr/bin/env, mirroring CLIAgentBrainAdapter.
//

import AppKit
import Darwin
import Foundation

@MainActor
final class OpenCodeServerManager {

    static let shared = OpenCodeServerManager()

    /// The running `opencode serve` process. Retained for the app's lifetime so the
    /// server stays alive across voice turns; terminated when the app quits.
    private var serverProcess: Process?

    /// Base URL of the running server (e.g. `http://127.0.0.1:51234`). Cached once ready.
    private var runningBaseURL: URL?

    /// In-flight startup, so concurrent `ensureRunning()` calls share one launch
    /// instead of racing to spawn several servers.
    private var startupTask: Task<URL, Error>?

    /// Short-timeout session used only for the readiness health-check probe.
    private let healthCheckSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    private init() {
        // Terminate the child server when the app quits so we don't leak an orphaned
        // process. Self-registering here keeps the lifecycle localized to this file
        // (no edits to CompanionManager required).
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { OpenCodeServerManager.shared.shutdown() }
        }
    }

    // MARK: - Status (read-only, for the Notch Agents tab)

    /// True when the server process exists and is currently running.
    var isRunning: Bool {
        serverProcess?.isRunning ?? false
    }

    /// The base URL of the running server, or nil if it isn't running yet.
    var baseURL: URL? {
        guard isRunning else { return nil }
        return runningBaseURL
    }

    /// True while a startup is in progress (process spawned, awaiting readiness).
    var isStarting: Bool {
        startupTask != nil
    }

    // MARK: - Public

    /// Returns the base URL of a ready `opencode serve` instance, spawning one on the
    /// first call and reusing it afterwards.
    /// - Parameter binaryPath: bare command name ("opencode") or an absolute path. The
    ///   first caller's value wins; later calls reuse the already-running server.
    func ensureRunning(binaryPath: String) async throws -> URL {
        // Already running and the process is still alive → reuse immediately.
        if let runningBaseURL, let serverProcess, serverProcess.isRunning {
            return runningBaseURL
        }

        // A startup is already underway → await the same launch.
        if let startupTask {
            return try await startupTask.value
        }

        let launch = Task { try await startServer(binaryPath: binaryPath) }
        startupTask = launch
        defer { startupTask = nil }

        do {
            let baseURL = try await launch.value
            runningBaseURL = baseURL
            return baseURL
        } catch {
            // Leave state clean so the next turn can retry from scratch.
            runningBaseURL = nil
            serverProcess?.terminate()
            serverProcess = nil
            throw error
        }
    }

    /// Terminates the server process. Called on app quit.
    func shutdown() {
        guard let serverProcess, serverProcess.isRunning else { return }
        print("🤖 opencode serve → terminating (app quit)")
        serverProcess.terminate()
        self.serverProcess = nil
        self.runningBaseURL = nil
    }

    // MARK: - Launch

    private func startServer(binaryPath: String) async throws -> URL {
        // Pick a free loopback port ourselves and pass it explicitly. This is more
        // robust than `--port 0` + scraping the chosen port from log output, whose
        // exact format varies by opencode version.
        let port = try Self.findFreeLoopbackTCPPort()
        let baseURL = URL(string: "http://127.0.0.1:\(port)")!

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            binaryPath, "serve",
            "--hostname", "127.0.0.1",
            "--port", "\(port)",
            "--print-logs"
        ]

        // GUI apps don't inherit the shell PATH; augment it so a bare "opencode"
        // resolves (same coverage as CLIAgentBrainAdapter).
        var environment = ProcessInfo.processInfo.environment
        let augmentedPath = "/opt/homebrew/bin:/usr/local/bin:\(NSHomeDirectory())/.local/bin:/usr/bin:/bin"
        environment["PATH"] = augmentedPath + ":" + (environment["PATH"] ?? "")
        process.environment = environment

        // Run from the user's home directory so opencode has a sensible project root.
        process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())

        // Drain stdout+stderr continuously. If we don't, the OS pipe buffer (~64KB)
        // fills and opencode blocks on its next log write, hanging the server.
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        let outputHandle = outputPipe.fileHandleForReading
        outputHandle.readabilityHandler = { handle in
            let chunk = handle.availableData
            // Empty data means EOF (server exited): stop observing so the handler
            // doesn't busy-spin. We nil it via the passed-in `handle`, so the closure
            // captures nothing.
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            guard let text = String(data: chunk, encoding: .utf8) else { return }
            let trimmed = text.trimmingCharacters(in: .newlines)
            if !trimmed.isEmpty { print("🤖 opencode: \(trimmed)") }
        }
        process.terminationHandler = { finishedProcess in
            print("🤖 opencode serve → exited (status \(finishedProcess.terminationStatus))")
        }

        try process.run()
        serverProcess = process
        print("🤖 opencode serve → launching on \(baseURL.absoluteString) (pid \(process.processIdentifier))")

        try await waitUntilReady(baseURL: baseURL, process: process)
        print("🤖 opencode serve → ready at \(baseURL.absoluteString)")
        return baseURL
    }

    /// Polls the server until it answers HTTP, or fails if it exits or times out.
    private func waitUntilReady(baseURL: URL, process: Process, timeout: TimeInterval = 15) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        // `GET /session` returns quickly once the HTTP routes are registered. Any HTTP
        // response (even an error status) proves the server is listening and ready.
        let probeURL = baseURL.appendingPathComponent("session")

        while Date() < deadline {
            if !process.isRunning {
                throw OpenCodeServerError.serverExitedDuringStartup(status: process.terminationStatus)
            }
            do {
                let (_, response) = try await healthCheckSession.data(from: probeURL)
                if response is HTTPURLResponse { return }
            } catch {
                // Connection refused while still booting — wait and retry.
            }
            try await Task.sleep(nanoseconds: 250_000_000) // 0.25s
        }
        throw OpenCodeServerError.startupTimedOut(seconds: timeout)
    }

    // MARK: - Free-port discovery

    /// Asks the kernel for a free loopback TCP port by binding to port 0 and reading
    /// back the assigned port, then releasing it. Small TOCTOU window before opencode
    /// re-binds it; the readiness probe catches the rare collision.
    nonisolated static func findFreeLoopbackTCPPort() throws -> UInt16 {
        let socketDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else {
            throw OpenCodeServerError.couldNotAllocatePort(reason: "socket() failed")
        }
        defer { close(socketDescriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0 // 0 → let the kernel choose a free port
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &address) { addressPointer in
            addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(socketDescriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            throw OpenCodeServerError.couldNotAllocatePort(reason: "bind() failed")
        }

        var boundAddress = sockaddr_in()
        var boundAddressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) { addressPointer in
            addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                getsockname(socketDescriptor, sockaddrPointer, &boundAddressLength)
            }
        }
        guard nameResult == 0 else {
            throw OpenCodeServerError.couldNotAllocatePort(reason: "getsockname() failed")
        }

        // sin_port is in network byte order.
        return UInt16(bigEndian: boundAddress.sin_port)
    }
}

// MARK: - Errors

enum OpenCodeServerError: LocalizedError {
    case couldNotAllocatePort(reason: String)
    case serverExitedDuringStartup(status: Int32)
    case startupTimedOut(seconds: TimeInterval)
    case requestFailed(statusCode: Int, body: String)
    case unexpectedResponse(detail: String)

    var errorDescription: String? {
        switch self {
        case .couldNotAllocatePort(let reason):
            return "opencode serve: could not pick a free port (\(reason))"
        case .serverExitedDuringStartup(let status):
            return "opencode serve exited during startup (status \(status)). Is `opencode` installed and on PATH, and a provider authenticated (`opencode auth login`)?"
        case .startupTimedOut(let seconds):
            return "opencode serve did not become ready within \(Int(seconds))s"
        case .requestFailed(let statusCode, let body):
            return "opencode server request failed (HTTP \(statusCode)): \(body)"
        case .unexpectedResponse(let detail):
            return "opencode server: unexpected response — \(detail)"
        }
    }
}
