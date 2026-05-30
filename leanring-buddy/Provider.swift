//
//  Provider.swift
//  leanring-buddy
//
//  A single shared Provider model: one endpoint + one API key, entered ONCE,
//  reused across the Brain / STT / TTS slots. Replaces the old design where
//  each slot owned its own baseURL+apiKey+model trio (forcing the user to
//  paste the same key up to three times).
//
//  Only OpenAI-compatible backends live in the shared pool. Self-contained
//  backends (claudeWorker, cliAgent, openCodeServer, appleOCR, assemblyAI,
//  appleSpeech, elevenLabs, system) stay OUT of the pool — a slot that selects
//  one of those ignores its `providerID`.
//
//  The three OpenAICompatible adapters are UNCHANGED: each slot resolves its
//  provider, then builds the legacy `*ProviderSettings` struct the existing
//  factories already consume (provider.baseURL + provider.apiKey + slot.model).
//

import Foundation

// MARK: - Capabilities

/// Which slots a provider's endpoint can serve. A single Mistral key, for
/// example, can carry `[.stt, .tts]`; OpenAI can carry all three.
struct ProviderCapabilities: OptionSet, Codable, Hashable {
    let rawValue: Int
    static let brain = ProviderCapabilities(rawValue: 1 << 0)  // /v1/chat/completions (vision)
    static let stt   = ProviderCapabilities(rawValue: 1 << 1)  // /v1/audio/transcriptions
    static let tts   = ProviderCapabilities(rawValue: 1 << 2)  // /v1/audio/speech + /v1/audio/voices

    static let all: ProviderCapabilities = [.brain, .stt, .tts]
}

// MARK: - Provider

/// The single source of endpoint + credentials. Entered once, referenced by
/// id from each slot config.
struct Provider: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String                       // user label, e.g. "Mistral", "LM Studio (local)"
    var baseURL: String                    // root only; adapters keep appending /v1/...
    var apiKey: String = ""                // entered ONCE; empty for local servers
    var capabilities: ProviderCapabilities // which slots may use this provider
    var docsURL: String? = nil             // "Documentation" link
    var apiKeyURL: String? = nil           // "Get API key" link

    init(
        id: UUID = UUID(),
        name: String,
        baseURL: String,
        apiKey: String = "",
        capabilities: ProviderCapabilities,
        docsURL: String? = nil,
        apiKeyURL: String? = nil
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.capabilities = capabilities
        self.docsURL = docsURL
        self.apiKeyURL = apiKeyURL
    }
}

// MARK: - Slot configs

/// Brain slot — references a shared provider (when `.openAICompat`) and keeps
/// the non-shared, brain-only knobs (Claude / CLI / OpenCode-server fields).
struct BrainSlotConfig: Codable {
    var providerType: BrainProviderType = .claudeWorker
    /// Set when `providerType == .openAICompat`; resolved against the shared pool.
    var providerID: UUID? = nil
    /// OpenAI-compat model (must be a vision model).
    var model: String = "qwen2.5-vl-7b-instruct"

    // Self-contained backend fields (NOT part of the shared pool).
    var claudeModel: String = "claude-sonnet-4-6"
    var cliCommand: String = "claude"
    var cliArgsTemplate: String = "-p {prompt} --output-format text --dangerously-skip-permissions"
    var openCodeModel: String = ""
    var openCodeBinaryPath: String = "opencode"
}

struct STTSlotConfig: Codable {
    var providerType: STTProviderType = .assemblyAI
    var providerID: UUID? = nil
    var model: String = "whisper-1"
}

struct TTSSlotConfig: Codable {
    var providerType: TTSProviderType = .elevenLabs
    var providerID: UUID? = nil
    var model: String = "kokoro"
    var voice: String = "af_heart"
    var speed: Double = 1.0
}

// MARK: - Store

/// Top-level container persisted under one new UserDefaults key.
struct ProviderStore: Codable {
    var providers: [Provider] = []
    var brain: BrainSlotConfig = .init()
    var stt: STTSlotConfig = .init()
    var tts: TTSSlotConfig = .init()

    /// Resolves the provider a slot references, if any.
    func provider(for id: UUID?) -> Provider? {
        guard let id else { return nil }
        return providers.first { $0.id == id }
    }
}

// MARK: - Slot → legacy settings bridges
//
// The existing factories (BrainProviderFactory / STTProviderFactory /
// TTSProviderFactory) and adapters are UNCHANGED. We build the legacy
// settings struct from (slot + resolved provider) and hand it to them.

extension BrainSlotConfig {
    /// Builds the legacy `BrainProviderSettings` the unchanged factory consumes.
    func legacySettings(provider: Provider?) -> BrainProviderSettings {
        var s = BrainProviderSettings()
        s.providerType = providerType
        s.claudeModel = claudeModel
        s.cliCommand = cliCommand
        s.cliArgsTemplate = cliArgsTemplate
        s.openCodeModel = openCodeModel
        s.openCodeBinaryPath = openCodeBinaryPath
        // OpenAI-compat fields come from the shared provider + slot model.
        s.openAICompatBaseURL = provider?.baseURL ?? ""
        s.openAICompatAPIKey = provider?.apiKey ?? ""
        s.openAICompatModel = model
        return s
    }
}

extension STTSlotConfig {
    func legacySettings(provider: Provider?) -> STTProviderSettings {
        var s = STTProviderSettings()
        s.providerType = providerType
        s.openAICompatBaseURL = provider?.baseURL ?? ""
        s.openAICompatAPIKey = provider?.apiKey ?? ""
        s.openAICompatModel = model
        return s
    }
}

extension TTSSlotConfig {
    func legacySettings(provider: Provider?) -> TTSProviderSettings {
        var s = TTSProviderSettings()
        s.providerType = providerType
        s.openAICompatBaseURL = provider?.baseURL ?? ""
        s.openAICompatAPIKey = provider?.apiKey ?? ""
        s.openAICompatModel = model
        s.openAICompatVoice = voice
        s.openAICompatSpeed = speed
        return s
    }
}

// MARK: - Factory + persistence + migration

enum ProviderStoreFactory {

    static let userDefaultsKey = "providerStore"

    // Legacy keys, read once during migration and kept one release for rollback.
    private static let legacyBrainKey = "brainProviderSettings"
    private static let legacySTTKey = "sttProviderSettings"
    private static let legacyTTSKey = "ttsProviderSettings"

    static func load() -> ProviderStore {
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey),
           let store = try? JSONDecoder().decode(ProviderStore.self, from: data) {
            return store
        }
        // No store yet → migrate legacy keys (or seed defaults).
        let migrated = migrateLegacy()
        save(migrated)
        return migrated
    }

    static func save(_ store: ProviderStore) {
        guard let data = try? JSONEncoder().encode(store) else { return }
        UserDefaults.standard.set(data, forKey: userDefaultsKey)
    }

    /// One-time migration from the three legacy structs to a single store.
    ///
    /// De-dups providers by (baseURL, apiKey) so a user who pasted ONE key into
    /// brain + STT + TTS ends up with ONE Provider carrying the union of their
    /// capabilities. Lossless: each slot keeps its exact model/voice/speed and
    /// resolves to the same baseURL/key it had before.
    static func migrateLegacy() -> ProviderStore {
        var store = ProviderStore()

        let legacyBrain: BrainProviderSettings? = decode(legacyBrainKey)
        let legacySTT: STTProviderSettings? = decode(legacySTTKey)
        let legacyTTS: TTSProviderSettings? = decode(legacyTTSKey)

        // Dedup pool keyed by (baseURL, apiKey). Returns the provider id to use.
        var pool: [String: UUID] = [:]
        func provider(
            baseURL: String,
            apiKey: String,
            capability: ProviderCapabilities
        ) -> UUID {
            let key = "\(baseURL)\u{0}\(apiKey)"
            if let existingID = pool[key],
               let idx = store.providers.firstIndex(where: { $0.id == existingID }) {
                // Same endpoint+key already known → widen its capabilities.
                store.providers[idx].capabilities.formUnion(capability)
                return existingID
            }
            let meta = knownMeta(forBaseURL: baseURL)
            let p = Provider(
                name: meta.name,
                baseURL: baseURL,
                apiKey: apiKey,
                capabilities: capability,
                docsURL: meta.docsURL,
                apiKeyURL: meta.apiKeyURL
            )
            store.providers.append(p)
            pool[key] = p.id
            return p.id
        }

        // ── Brain ────────────────────────────────────────────────────────
        if let b = legacyBrain {
            store.brain.providerType = b.providerType
            store.brain.claudeModel = b.claudeModel
            store.brain.cliCommand = b.cliCommand
            store.brain.cliArgsTemplate = b.cliArgsTemplate
            store.brain.openCodeModel = b.openCodeModel
            store.brain.openCodeBinaryPath = b.openCodeBinaryPath
            store.brain.model = b.openAICompatModel
            if b.providerType == .openAICompat {
                store.brain.providerID = provider(
                    baseURL: b.openAICompatBaseURL,
                    apiKey: b.openAICompatAPIKey,
                    capability: .brain
                )
            }
        }

        // ── STT ──────────────────────────────────────────────────────────
        if let s = legacySTT {
            store.stt.providerType = s.providerType
            store.stt.model = s.openAICompatModel
            if s.providerType == .openAICompat {
                store.stt.providerID = provider(
                    baseURL: s.openAICompatBaseURL,
                    apiKey: s.openAICompatAPIKey,
                    capability: .stt
                )
            }
        }

        // ── TTS ──────────────────────────────────────────────────────────
        if let t = legacyTTS {
            store.tts.providerType = t.providerType
            // Carry over the in-flight model fixup that lived in TTSProviderFactory.
            var ttsModel = t.openAICompatModel
            if ttsModel == "mistral-tts-latest" { ttsModel = "voxtral-mini-tts-2603" }
            store.tts.model = ttsModel
            store.tts.voice = t.openAICompatVoice
            store.tts.speed = t.openAICompatSpeed
            if t.providerType == .openAICompat {
                store.tts.providerID = provider(
                    baseURL: t.openAICompatBaseURL,
                    apiKey: t.openAICompatAPIKey,
                    capability: .tts
                )
            }
        }

        // If nothing migrated and no providers exist, seed friendly defaults.
        if store.providers.isEmpty {
            store.providers = Self.seededDefaults()
        }

        return store
    }

    /// Friendly defaults with doc/key links prefilled (used when no legacy data).
    static func seededDefaults() -> [Provider] {
        [
            Provider(
                name: "LM Studio (local)",
                baseURL: "http://localhost:1234",
                apiKey: "",
                capabilities: .brain,
                docsURL: "https://lmstudio.ai/docs",
                apiKeyURL: nil
            ),
            Provider(
                name: "OpenAI",
                baseURL: "https://api.openai.com",
                apiKey: "",
                capabilities: .all,
                docsURL: "https://platform.openai.com/docs",
                apiKeyURL: "https://platform.openai.com/api-keys"
            ),
            Provider(
                name: "Mistral",
                baseURL: "https://api.mistral.ai",
                apiKey: "",
                capabilities: [.stt, .tts],
                docsURL: "https://docs.mistral.ai",
                apiKeyURL: "https://console.mistral.ai/api-keys"
            )
        ]
    }

    // Friendly name + doc/key links inferred from a baseURL during migration.
    private static func knownMeta(
        forBaseURL baseURL: String
    ) -> (name: String, docsURL: String?, apiKeyURL: String?) {
        let lower = baseURL.lowercased()
        if lower.contains("api.openai.com") {
            return ("OpenAI", "https://platform.openai.com/docs", "https://platform.openai.com/api-keys")
        }
        if lower.contains("api.mistral.ai") {
            return ("Mistral", "https://docs.mistral.ai", "https://console.mistral.ai/api-keys")
        }
        if lower.contains("localhost:1234") || lower.contains("127.0.0.1:1234") {
            return ("LM Studio (local)", "https://lmstudio.ai/docs", nil)
        }
        if lower.contains("8880") {
            return ("Voicebox (local)", nil, nil)
        }
        if lower.contains("localhost") || lower.contains("127.0.0.1") {
            return ("Local server", nil, nil)
        }
        return (baseURL, nil, nil)
    }

    private static func decode<T: Decodable>(_ key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - OpenAI model catalog
//
// Mirrors OpenCodeModelCatalog: a stateless enum with a static async fetch
// returning sorted Identifiable infos, lenient JSON parsing, used to drive a
// real Picker in Settings with a free-text fallback.

struct OpenAIModelInfo: Identifiable, Hashable {
    let id: String          // model id from data[].id
    var menuLabel: String { id }
}

enum OpenAIModelCatalog {
    /// GET \(baseURL)/v1/models  → { "data": [ { "id": String } ] }.
    /// Works for OpenAI, Mistral, LM Studio. Sorted by id. Bearer header if key set.
    static func fetch(baseURL: String, apiKey: String?) async throws -> [OpenAIModelInfo] {
        guard let url = URL(string: trimmedBase(baseURL) + "/v1/models") else {
            throw NSError(domain: "OpenAIModelCatalog", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid base URL"])
        }
        var request = URLRequest(url: url)
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "OpenAIModelCatalog", code: code,
                          userInfo: [NSLocalizedDescriptionKey: "GET /v1/models failed (\(code))"])
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        // Tolerate { "data": [...] } or a bare array.
        let rawList = (json["data"] as? [[String: Any]]) ?? []
        var ids = Set<String>()
        for item in rawList {
            if let id = item["id"] as? String, !id.isEmpty { ids.insert(id) }
        }
        return ids.sorted { $0.lowercased() < $1.lowercased() }.map { OpenAIModelInfo(id: $0) }
    }

    private static func trimmedBase(_ s: String) -> String {
        var b = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while b.hasSuffix("/") { b.removeLast() }
        return b
    }
}

// MARK: - OpenAI voice catalog

struct OpenAIVoiceInfo: Identifiable, Hashable {
    let id: String          // voice id used in the speech request
    let name: String        // display name (falls back to id)
    var menuLabel: String { id == name ? id : "\(name)  ·  \(id)" }
}

enum OpenAIVoiceCatalog {
    /// GET \(baseURL)/v1/audio/voices?limit=1000  — the high limit is MANDATORY:
    /// Mistral paginates ~10/page and has 30 voices (incl. the French fr_marie_*),
    /// so without it the French voices silently vanish from the picker.
    /// Tolerates { "voices": [...] }, { "data": [...] }, or a bare array.
    static func fetch(baseURL: String, apiKey: String?) async throws -> [OpenAIVoiceInfo] {
        guard let url = URL(string: trimmedBase(baseURL) + "/v1/audio/voices?limit=1000") else {
            throw NSError(domain: "OpenAIVoiceCatalog", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid base URL"])
        }
        var request = URLRequest(url: url)
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "OpenAIVoiceCatalog", code: code,
                          userInfo: [NSLocalizedDescriptionKey: "GET /v1/audio/voices failed (\(code))"])
        }

        // Extract the array of voice objects regardless of envelope shape.
        let rawList: [Any]
        if let arr = try? JSONSerialization.jsonObject(with: data) as? [Any] {
            rawList = arr
        } else if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            rawList = (obj["voices"] as? [Any]) ?? (obj["data"] as? [Any]) ?? []
        } else {
            return []
        }

        var seen = Set<String>()
        var results: [OpenAIVoiceInfo] = []
        for item in rawList {
            if let s = item as? String {
                // Bare array of voice id strings.
                if !s.isEmpty, seen.insert(s).inserted {
                    results.append(OpenAIVoiceInfo(id: s, name: s))
                }
            } else if let dict = item as? [String: Any] {
                let id = (dict["id"] as? String)
                    ?? (dict["name"] as? String)
                    ?? (dict["voice"] as? String)
                guard let id, !id.isEmpty, seen.insert(id).inserted else { continue }
                let name = (dict["name"] as? String) ?? id
                results.append(OpenAIVoiceInfo(id: id, name: name))
            }
        }
        return results.sorted { $0.id.lowercased() < $1.id.lowercased() }
    }

    private static func trimmedBase(_ s: String) -> String {
        var b = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while b.hasSuffix("/") { b.removeLast() }
        return b
    }
}
