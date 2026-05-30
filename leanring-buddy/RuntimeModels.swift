//
//  RuntimeModels.swift
//  leanring-buddy
//
//  Command and Event envelope types for the Clicky runtime.
//  Schema mirrors the observed layout in the commercial app's runtime.sqlite.
//
//  Commands flow inward  (caller → RuntimeCoordinator → Harness).
//  Events flow outward   (Harness → RuntimeCoordinator → subscribers).
//  Both are persisted to SQLite so sessions are fully replayable.
//

import Foundation

// MARK: - Session

struct RuntimeSession: Codable, Identifiable {
    let id: String
    let createdAt: Date
    var updatedAt: Date
    var status: SessionStatus
    let harnessType: HarnessType
    var capabilitiesJSON: String
    var toolPolicyJSON: String

    enum SessionStatus: String, Codable {
        case booting, running, completed, interrupted, error
    }
}

// MARK: - Harness metadata

enum HarnessType: String, Codable {
    case api            // HTTP vision+stream (ClaudeAPI / OpenAI / local)
    case codex          // swift-codex-app-server-bridge
    case claudeCode     = "claude-code"  // headless SDK / MCP
    case opencode       // opencode CLI/SDK
}

struct HarnessCapabilities: Codable {
    let harnessType: HarnessType
    /// Wire protocol: "http_stream" | "stdio" | "app_server"
    let transport: String
    /// Which lifecycle controls the harness supports
    let controls: [String]
    /// Context isolation strategy: "isolated" | "summary" | "fork"
    let contextIsolation: String
    /// How the harness signals turn completion back to the runtime
    let completion: String

    static let defaultAPI = HarnessCapabilities(
        harnessType: .api,
        transport: "http_stream",
        controls: ["send", "stop"],
        contextIsolation: "summary",
        completion: "pushToRootRuntime"
    )
}

struct HarnessToolPolicy: Codable {
    var shell: Bool = false
    var screen: Bool = true
    var memoryRead: Bool = true
    var memoryWrite: Bool = true
    var maxSpawnDepth: Int = 0
    var childSpawn: Bool = false

    static let defaultAPI = HarnessToolPolicy()
}

// MARK: - Command envelope

struct RuntimeCommandEnvelope: Codable, Identifiable {
    let id: String
    let sessionId: String
    let issuedAt: Date
    let commandType: RuntimeCommandType
    let payloadJSON: String

    init(sessionId: String, command: RuntimeCommand) throws {
        self.id = UUID().uuidString
        self.sessionId = sessionId
        self.issuedAt = Date()
        self.commandType = command.commandType
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.payloadJSON = String(data: try encoder.encode(command), encoding: .utf8) ?? "{}"
    }
}

enum RuntimeCommandType: String, Codable {
    case boot                   = "BootRuntimeCommand"
    case sendVoiceTurn          = "SendVoiceTurnCommand"
    case sendTextTurn           = "SendTextTurnCommand"
    case interruptRootTurn      = "InterruptRootTurnCommand"
    case submitScreenContext     = "SubmitScreenContextCommand"
    case requestChildTask        = "RequestChildTaskCommand"
    case cancelChildTask         = "CancelChildTaskCommand"
    case pauseChildTask          = "PauseChildTaskCommand"
    case resumeChildTask         = "ResumeChildTaskCommand"
    case stopChildTask           = "StopChildTaskCommand"
    case requestStatus           = "RequestRuntimeStatusCommand"
    case saveMemory              = "SaveMemoryCommand"
    case getMemory               = "GetMemoryCommand"
    case listMemory              = "ListMemoryCommand"
    case searchMemory            = "SearchMemoryCommand"
    case removeMemory            = "RemoveMemoryCommand"
}

// MARK: - Commands

enum RuntimeCommand: Codable {
    case boot(BootRuntimeCommand)
    case sendVoiceTurn(SendVoiceTurnCommand)
    case sendTextTurn(SendTextTurnCommand)
    case interruptRootTurn(InterruptRootTurnCommand)
    case submitScreenContext(SubmitScreenContextCommand)
    case requestChildTask(RequestChildTaskCommand)
    case cancelChildTask(CancelChildTaskCommand)
    case saveMemory(SaveMemoryCommand)
    case getMemory(GetMemoryCommand)
    case listMemory(ListMemoryCommand)
    case searchMemory(SearchMemoryCommand)
    case removeMemory(RemoveMemoryCommand)
    case requestStatus(RequestRuntimeStatusCommand)

    var commandType: RuntimeCommandType {
        switch self {
        case .boot:               return .boot
        case .sendVoiceTurn:      return .sendVoiceTurn
        case .sendTextTurn:       return .sendTextTurn
        case .interruptRootTurn:  return .interruptRootTurn
        case .submitScreenContext: return .submitScreenContext
        case .requestChildTask:   return .requestChildTask
        case .cancelChildTask:    return .cancelChildTask
        case .saveMemory:         return .saveMemory
        case .getMemory:          return .getMemory
        case .listMemory:         return .listMemory
        case .searchMemory:       return .searchMemory
        case .removeMemory:       return .removeMemory
        case .requestStatus:      return .requestStatus
        }
    }
}

struct BootRuntimeCommand: Codable {
    let harnessType: HarnessType
    let capabilities: HarnessCapabilities
    let toolPolicy: HarnessToolPolicy
    /// Optional system prompt override; nil = use default companion prompt
    let systemPromptOverride: String?
}

struct SendVoiceTurnCommand: Codable {
    /// The finalized transcript from STT
    let transcript: String
    /// Base64-encoded screenshot data per connected screen (empty = no screen context)
    let screenshotBase64PerScreen: [ScreenCaptureSummary]
    let turnId: String

    init(transcript: String, screenshotBase64PerScreen: [ScreenCaptureSummary] = []) {
        self.transcript = transcript
        self.screenshotBase64PerScreen = screenshotBase64PerScreen
        self.turnId = UUID().uuidString
    }
}

struct SendTextTurnCommand: Codable {
    let text: String
    let turnId: String

    init(text: String) {
        self.text = text
        self.turnId = UUID().uuidString
    }
}

struct InterruptRootTurnCommand: Codable {
    let reason: String
    init(reason: String = "user_interrupt") { self.reason = reason }
}

struct SubmitScreenContextCommand: Codable {
    let screenshotBase64PerScreen: [ScreenCaptureSummary]
}

struct RequestChildTaskCommand: Codable {
    let taskDescription: String
    let harnessType: HarnessType
    let childSessionId: String
    init(taskDescription: String, harnessType: HarnessType) {
        self.taskDescription = taskDescription
        self.harnessType = harnessType
        self.childSessionId = UUID().uuidString
    }
}

struct CancelChildTaskCommand: Codable {
    let childSessionId: String
}

struct SaveMemoryCommand: Codable {
    let key: String
    let value: String
    let tags: [String]
    init(key: String, value: String, tags: [String] = []) {
        self.key = key; self.value = value; self.tags = tags
    }
}

struct GetMemoryCommand: Codable {
    let key: String
}

struct ListMemoryCommand: Codable {
    let tag: String?
    init(tag: String? = nil) { self.tag = tag }
}

struct SearchMemoryCommand: Codable {
    let query: String
    let limit: Int
    init(query: String, limit: Int = 10) { self.query = query; self.limit = limit }
}

struct RemoveMemoryCommand: Codable {
    let key: String
}

struct RequestRuntimeStatusCommand: Codable {}

/// Lightweight capture summary passed with a voice turn command.
/// Avoids embedding large base64 blobs in the command JSON stored in SQLite;
/// the runtime fetches screenshots fresh at turn time from CompanionScreenCaptureUtility.
struct ScreenCaptureSummary: Codable {
    let screenLabel: String
    let widthPixels: Int
    let heightPixels: Int
    let isCursorScreen: Bool
}

// MARK: - Event envelope

struct RuntimeEventEnvelope: Codable, Identifiable {
    let id: String
    let sessionId: String
    let occurredAt: Date
    let sequenceNumber: Int
    let eventType: RuntimeEventType
    let payloadJSON: String

    init(sessionId: String, sequenceNumber: Int, event: RuntimeEventPayload) throws {
        self.id = UUID().uuidString
        self.sessionId = sessionId
        self.occurredAt = Date()
        self.sequenceNumber = sequenceNumber
        self.eventType = event.eventType
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.payloadJSON = String(data: try encoder.encode(event), encoding: .utf8) ?? "{}"
    }
}

enum RuntimeEventType: String, Codable {
    case runtimeReady             = "RuntimeReadyEvent"
    case rootTurnStarted          = "RootTurnStartedEvent"
    case rootTurnCompleted        = "RootTurnCompletedEvent"
    case rootTurnInterrupted      = "RootTurnInterruptedEvent"
    case rootTokenDelta           = "RootTokenDeltaEvent"
    case toolCallStarted          = "ToolCallStartedEvent"
    case toolCallCompleted        = "ToolCallCompletedEvent"
    case toolExecutionRequested   = "ToolExecutionRequestedEvent"
    case childSessionCreated      = "ChildSessionCreatedEvent"
    case childSessionUpdated      = "ChildSessionUpdatedEvent"
    case needsUserConfirmation    = "NeedsUserConfirmationEvent"
    case degradedStateChanged     = "DegradedStateChangedEvent"
    case runtimeError             = "RuntimeErrorEvent"
    case agentCompletion          = "AgentCompletionEvent"
    case memoryUpdated            = "MemoryUpdatedEvent"
}

// MARK: - Events

enum RuntimeEventPayload: Codable {
    case runtimeReady(RuntimeReadyEvent)
    case rootTurnStarted(RootTurnStartedEvent)
    case rootTurnCompleted(RootTurnCompletedEvent)
    case rootTurnInterrupted(RootTurnInterruptedEvent)
    case rootTokenDelta(RootTokenDeltaEvent)
    case toolCallStarted(ToolCallStartedEvent)
    case toolCallCompleted(ToolCallCompletedEvent)
    case toolExecutionRequested(ToolExecutionRequestedEvent)
    case childSessionCreated(ChildSessionCreatedEvent)
    case childSessionUpdated(ChildSessionUpdatedEvent)
    case needsUserConfirmation(NeedsUserConfirmationEvent)
    case degradedStateChanged(DegradedStateChangedEvent)
    case runtimeError(RuntimeErrorEvent)
    case agentCompletion(AgentCompletionEvent)
    case memoryUpdated(MemoryUpdatedEvent)

    var eventType: RuntimeEventType {
        switch self {
        case .runtimeReady:           return .runtimeReady
        case .rootTurnStarted:        return .rootTurnStarted
        case .rootTurnCompleted:      return .rootTurnCompleted
        case .rootTurnInterrupted:    return .rootTurnInterrupted
        case .rootTokenDelta:         return .rootTokenDelta
        case .toolCallStarted:        return .toolCallStarted
        case .toolCallCompleted:      return .toolCallCompleted
        case .toolExecutionRequested: return .toolExecutionRequested
        case .childSessionCreated:    return .childSessionCreated
        case .childSessionUpdated:    return .childSessionUpdated
        case .needsUserConfirmation:  return .needsUserConfirmation
        case .degradedStateChanged:   return .degradedStateChanged
        case .runtimeError:           return .runtimeError
        case .agentCompletion:        return .agentCompletion
        case .memoryUpdated:          return .memoryUpdated
        }
    }
}

struct RuntimeReadyEvent: Codable {
    let harnessType: HarnessType
    let capabilities: HarnessCapabilities
}

struct RootTurnStartedEvent: Codable {
    let turnId: String
    let inputSummary: String  // e.g. "voice: <first 60 chars of transcript>"
}

struct RootTurnCompletedEvent: Codable {
    let turnId: String
    let fullResponseText: String
    let durationSeconds: Double
    let tokenCount: Int
}

struct RootTurnInterruptedEvent: Codable {
    let turnId: String
    let reason: String
}

struct RootTokenDeltaEvent: Codable {
    let turnId: String
    /// Incremental text chunk (not accumulated — the same chunk shape as SSE)
    let delta: String
    /// Accumulated text so far, for convenience
    let accumulated: String
}

struct ToolCallStartedEvent: Codable {
    let toolCallId: String
    let toolName: String
    let inputJSON: String
}

struct ToolCallCompletedEvent: Codable {
    let toolCallId: String
    let toolName: String
    let outputJSON: String
    let durationSeconds: Double
}

struct ToolExecutionRequestedEvent: Codable {
    let toolCallId: String
    let toolName: String
    let inputJSON: String
    let requiresConfirmation: Bool
}

struct ChildSessionCreatedEvent: Codable {
    let childSessionId: String
    let parentSessionId: String
    let harnessType: HarnessType
    let taskDescription: String
}

struct ChildSessionUpdatedEvent: Codable {
    let childSessionId: String
    let status: RuntimeSession.SessionStatus
    let summary: String?
}

struct NeedsUserConfirmationEvent: Codable {
    let toolCallId: String
    let toolName: String
    let question: String
}

struct DegradedStateChangedEvent: Codable {
    let isDegraded: Bool
    let reason: String?
}

struct RuntimeErrorEvent: Codable {
    let errorCode: String
    let message: String
    let isFatal: Bool
}

struct AgentCompletionEvent: Codable {
    let sessionId: String
    let summary: String
    let artifactIds: [String]
}

struct MemoryUpdatedEvent: Codable {
    enum Operation: String, Codable { case saved, removed }
    let operation: Operation
    let key: String
    let value: String?
}

// MARK: - Memory entry

struct RuntimeMemoryEntry: Codable, Identifiable {
    let id: String
    let createdAt: Date
    var updatedAt: Date
    let key: String
    var value: String
    var tags: [String]
    let sessionId: String?

    init(key: String, value: String, tags: [String] = [], sessionId: String? = nil) {
        self.id = UUID().uuidString
        self.createdAt = Date()
        self.updatedAt = Date()
        self.key = key
        self.value = value
        self.tags = tags
        self.sessionId = sessionId
    }
}
