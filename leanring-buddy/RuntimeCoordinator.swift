//
//  RuntimeCoordinator.swift
//  leanring-buddy
//
//  The runtime backbone. Receives commands from the app layer, dispatches
//  them to the active harness, persists every session + event to RuntimeStore,
//  and publishes a Combine stream of RuntimeEventEnvelopes that any consumer
//  (UI Notch, Integrations, Scheduling) can subscribe to.
//
//  Architecture:
//    CompanionManager  →  send(command)  →  RuntimeCoordinator
//    RuntimeCoordinator  →  harness.sendVoiceTurn  →  APIHarnessAdapter / …
//    RuntimeCoordinator  →  eventPublisher  →  UI Notch / Integrations / Scheduling
//    RuntimeCoordinator  →  RuntimeStore  →  runtime.sqlite
//

import Combine
import Foundation

@MainActor
final class RuntimeCoordinator: ObservableObject {

    // MARK: - Public state

    /// The currently active session, if any. Observed by the UI.
    @Published private(set) var activeSession: RuntimeSession?

    /// Whether a root turn is currently in flight (harness is processing).
    @Published private(set) var isTurnInProgress: Bool = false

    /// Accumulated token text for the current root turn.
    /// Consumers that want progressive display subscribe to this.
    @Published private(set) var currentTurnAccumulatedText: String = ""

    /// All events from all sessions, in the order they were emitted.
    /// Subscribers receive every event the runtime emits.
    let eventPublisher = PassthroughSubject<RuntimeEventEnvelope, Never>()

    // MARK: - Private

    private let store: RuntimeStore
    private var activeHarness: (any RuntimeHarness)?
    private var currentTurnTask: Task<Void, Never>?

    /// System prompt stored at boot time (passed via BootRuntimeCommand.systemPromptOverride).
    private var runtimeSystemPrompt: String = ""

    /// In-memory conversation history for the active session (mirrors what's in events but
    /// kept here for cheap access when building each turn's context).
    private var conversationHistory: [(userTranscript: String, assistantResponse: String)] = []

    /// Monotonically-increasing event sequence number for the active session.
    private var nextEventSequenceNumber: Int = 1

    // MARK: - Init

    init() {
        do {
            self.store = try RuntimeStore()
        } catch {
            // Store failure is non-fatal at boot — runtime operates in-memory only
            fatalError("RuntimeStore init failed: \(error)")
        }
    }

    // MARK: - Command gateway

    /// The single entry point for all app-layer commands.
    func send(_ command: RuntimeCommand) async {
        do {
            try await dispatch(command)
        } catch {
            await emitEvent(.runtimeError(RuntimeErrorEvent(
                errorCode: "dispatch_error",
                message: error.localizedDescription,
                isFatal: false
            )))
            print("⚠️ RuntimeCoordinator: command failed — \(error)")
        }
    }

    // MARK: - Dispatch

    private func dispatch(_ command: RuntimeCommand) async throws {
        // Persist the command envelope (best-effort — failure doesn't block execution)
        if let session = activeSession {
            let envelope = try? RuntimeCommandEnvelope(sessionId: session.id, command: command)
            if let envelope {
                try? await store.appendCommandEnvelope(envelope)
            }
        }

        switch command {
        case .boot(let cmd):
            try await handleBoot(cmd)

        case .sendVoiceTurn(let cmd):
            await handleVoiceTurn(cmd)

        case .sendTextTurn(let cmd):
            await handleTextTurn(cmd)

        case .interruptRootTurn(let cmd):
            await handleInterrupt(cmd)

        case .saveMemory(let cmd):
            try await handleSaveMemory(cmd)

        case .getMemory(let cmd):
            try await handleGetMemory(cmd)

        case .listMemory(let cmd):
            try await handleListMemory(cmd)

        case .searchMemory(let cmd):
            try await handleSearchMemory(cmd)

        case .removeMemory(let cmd):
            try await handleRemoveMemory(cmd)

        case .requestStatus:
            await emitEvent(.runtimeReady(RuntimeReadyEvent(
                harnessType: activeHarness?.harnessType ?? .api,
                capabilities: activeHarness?.capabilities ?? .defaultAPI
            )))

        default:
            print("⚠️ RuntimeCoordinator: unhandled command \(command.commandType)")
        }
    }

    // MARK: - Boot

    private func handleBoot(_ command: BootRuntimeCommand) async throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let capJSON = String(data: (try? encoder.encode(command.capabilities)) ?? Data(), encoding: .utf8) ?? "{}"
        let policyJSON = String(data: (try? encoder.encode(command.toolPolicy)) ?? Data(), encoding: .utf8) ?? "{}"

        let session = RuntimeSession(
            id: UUID().uuidString,
            createdAt: Date(),
            updatedAt: Date(),
            status: .booting,
            harnessType: command.harnessType,
            capabilitiesJSON: capJSON,
            toolPolicyJSON: policyJSON
        )
        try await store.insertSession(session)
        activeSession = session
        nextEventSequenceNumber = 1
        conversationHistory = []
        currentTurnAccumulatedText = ""
        runtimeSystemPrompt = command.systemPromptOverride ?? ""

        print("🚀 RuntimeCoordinator: booted session \(session.id) with harness \(command.harnessType.rawValue)")
        await emitEvent(.runtimeReady(RuntimeReadyEvent(
            harnessType: command.harnessType,
            capabilities: command.capabilities
        )))
        try await store.updateSessionStatus(session.id, status: .running)
        activeSession?.status = .running
    }

    // MARK: - Voice turn

    private func handleVoiceTurn(_ command: SendVoiceTurnCommand) async {
        guard let session = activeSession, let harness = activeHarness else {
            print("⚠️ RuntimeCoordinator: voice turn received but no active session/harness — boot first")
            return
        }

        // Cancel any in-flight turn
        currentTurnTask?.cancel()

        isTurnInProgress = true
        currentTurnAccumulatedText = ""

        await emitEvent(.rootTurnStarted(RootTurnStartedEvent(
            turnId: command.turnId,
            inputSummary: "voice: \(command.transcript.prefix(60))"
        )))

        currentTurnTask = Task { [weak self] in
            guard let self else { return }
            do {
                var accumulated = ""

                let fullResponse = try await harness.sendVoiceTurn(
                    turnId: command.turnId,
                    transcript: command.transcript,
                    images: [],  // Images are fetched by CompanionManager before sending the command
                    conversationHistory: conversationHistory,
                    systemPrompt: runtimeSystemPrompt,
                    onTokenDelta: { [weak self] delta in
                        guard let self else { return }
                        accumulated += delta
                        self.currentTurnAccumulatedText = accumulated
                        Task { @MainActor [weak self] in
                            await self?.emitEvent(.rootTokenDelta(RootTokenDeltaEvent(
                                turnId: command.turnId,
                                delta: delta,
                                accumulated: accumulated
                            )))
                        }
                    }
                )

                guard !Task.isCancelled else { return }

                conversationHistory.append((
                    userTranscript: command.transcript,
                    assistantResponse: fullResponse
                ))
                if conversationHistory.count > 10 {
                    conversationHistory.removeFirst(conversationHistory.count - 10)
                }

                await emitEvent(.rootTurnCompleted(RootTurnCompletedEvent(
                    turnId: command.turnId,
                    fullResponseText: fullResponse,
                    durationSeconds: 0,
                    tokenCount: fullResponse.split(separator: " ").count
                )))

            } catch is CancellationError {
                await emitEvent(.rootTurnInterrupted(RootTurnInterruptedEvent(
                    turnId: command.turnId, reason: "cancelled"
                )))
            } catch {
                await emitEvent(.runtimeError(RuntimeErrorEvent(
                    errorCode: "turn_error", message: error.localizedDescription, isFatal: false
                )))
            }

            self.isTurnInProgress = false
            self.currentTurnTask = nil
        }
    }

    // MARK: - Text turn

    private func handleTextTurn(_ command: SendTextTurnCommand) async {
        guard let harness = activeHarness else { return }
        currentTurnTask?.cancel()
        isTurnInProgress = true
        currentTurnAccumulatedText = ""

        await emitEvent(.rootTurnStarted(RootTurnStartedEvent(
            turnId: command.turnId,
            inputSummary: "text: \(command.text.prefix(60))"
        )))

        currentTurnTask = Task { [weak self] in
            guard let self else { return }
            do {
                var accumulated = ""

                let fullResponse = try await harness.sendTextTurn(
                    turnId: command.turnId,
                    text: command.text,
                    conversationHistory: conversationHistory,
                    systemPrompt: runtimeSystemPrompt,
                    onTokenDelta: { [weak self] delta in
                        guard let self else { return }
                        accumulated += delta
                        self.currentTurnAccumulatedText = accumulated
                        Task { @MainActor [weak self] in
                            await self?.emitEvent(.rootTokenDelta(RootTokenDeltaEvent(
                                turnId: command.turnId, delta: delta, accumulated: accumulated
                            )))
                        }
                    }
                )

                guard !Task.isCancelled else { return }

                conversationHistory.append((userTranscript: command.text, assistantResponse: fullResponse))
                if conversationHistory.count > 10 {
                    conversationHistory.removeFirst(conversationHistory.count - 10)
                }

                await emitEvent(.rootTurnCompleted(RootTurnCompletedEvent(
                    turnId: command.turnId,
                    fullResponseText: fullResponse,
                    durationSeconds: 0,
                    tokenCount: fullResponse.split(separator: " ").count
                )))
            } catch is CancellationError {
                await emitEvent(.rootTurnInterrupted(RootTurnInterruptedEvent(
                    turnId: command.turnId, reason: "cancelled"
                )))
            } catch {
                await emitEvent(.runtimeError(RuntimeErrorEvent(
                    errorCode: "turn_error", message: error.localizedDescription, isFatal: false
                )))
            }
            self.isTurnInProgress = false
        }
    }

    // MARK: - Interrupt

    private func handleInterrupt(_ command: InterruptRootTurnCommand) async {
        guard isTurnInProgress else { return }
        currentTurnTask?.cancel()
        await activeHarness?.interrupt()
        isTurnInProgress = false
    }

    // MARK: - Memory

    private func handleSaveMemory(_ command: SaveMemoryCommand) async throws {
        guard let session = activeSession else { return }
        let entry = RuntimeMemoryEntry(key: command.key, value: command.value,
                                       tags: command.tags, sessionId: session.id)
        try await store.upsertMemory(entry)
        await emitEvent(.memoryUpdated(MemoryUpdatedEvent(operation: .saved, key: command.key, value: command.value)))
        print("🧠 RuntimeStore memory: saved '\(command.key)'")
    }

    private func handleGetMemory(_ command: GetMemoryCommand) async throws {
        let entry = try await store.fetchMemory(key: command.key)
        if let entry {
            print("🧠 RuntimeStore memory: get '\(command.key)' → \(entry.value.prefix(60))")
        }
        // Emit as an event so callers can observe the value
        await emitEvent(.memoryUpdated(MemoryUpdatedEvent(operation: .saved, key: command.key, value: entry?.value)))
    }

    private func handleListMemory(_ command: ListMemoryCommand) async throws {
        let entries = try await store.listMemory(tag: command.tag)
        print("🧠 RuntimeStore memory: list(\(command.tag ?? "*")) → \(entries.count) entries")
        // Emit one event per entry (callers that need the full list subscribe to the stream)
        for entry in entries {
            await emitEvent(.memoryUpdated(MemoryUpdatedEvent(operation: .saved, key: entry.key, value: entry.value)))
        }
    }

    private func handleSearchMemory(_ command: SearchMemoryCommand) async throws {
        let entries = try await store.searchMemory(query: command.query, limit: command.limit)
        print("🧠 RuntimeStore memory: search '\(command.query)' → \(entries.count) results")
        for entry in entries {
            await emitEvent(.memoryUpdated(MemoryUpdatedEvent(operation: .saved, key: entry.key, value: entry.value)))
        }
    }

    private func handleRemoveMemory(_ command: RemoveMemoryCommand) async throws {
        try await store.removeMemory(key: command.key)
        await emitEvent(.memoryUpdated(MemoryUpdatedEvent(operation: .removed, key: command.key, value: nil)))
        print("🧠 RuntimeStore memory: removed '\(command.key)'")
    }

    // MARK: - Event emission

    @discardableResult
    private func emitEvent(_ payload: RuntimeEventPayload) async -> RuntimeEventEnvelope? {
        guard let session = activeSession else {
            // Emit without persistence if no session is active yet (e.g. RuntimeReady on boot)
            if let envelope = try? RuntimeEventEnvelope(sessionId: "", sequenceNumber: 0, event: payload) {
                eventPublisher.send(envelope)
            }
            return nil
        }

        let seqNum = nextEventSequenceNumber
        nextEventSequenceNumber += 1

        guard let envelope = try? RuntimeEventEnvelope(sessionId: session.id,
                                                        sequenceNumber: seqNum,
                                                        event: payload) else { return nil }

        // Persist asynchronously (best-effort)
        Task.detached { [store] in
            try? await store.appendEvent(envelope)
        }

        eventPublisher.send(envelope)
        return envelope
    }

    // MARK: - Harness management

    /// Replaces the active harness. Call before `.boot` or between sessions.
    func setHarness(_ harness: any RuntimeHarness) {
        activeHarness = harness
    }
}
