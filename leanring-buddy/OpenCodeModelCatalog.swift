//
//  OpenCodeModelCatalog.swift
//  leanring-buddy
//
//  Fetches the available models + their capabilities from a running `opencode
//  serve` instance, so Settings can show a real dropdown (no typing slugs) with
//  per-model capability badges (vision / reasoning / tools).
//
//  Source: GET /config/providers on the opencode server returns
//    { "providers": [ { "id", "name", "models": { "<modelID>": {
//        "name", "capabilities": { "reasoning": Bool, "toolcall": Bool,
//          "input": { "image": Bool, ... }, ... } } } } ] }
//  Vision = capabilities.input.image == true.
//

import Foundation

struct OpenCodeModelInfo: Identifiable, Hashable {
    let providerID: String
    let modelID: String
    let name: String
    let hasVision: Bool
    let hasReasoning: Bool
    let hasTools: Bool

    /// "providerID/modelID" — the selector the brain client / server expects.
    var id: String { "\(providerID)/\(modelID)" }

    /// Emoji capability badges, e.g. "👁 🧠 🔧".
    var badges: String {
        var parts: [String] = []
        if hasVision { parts.append("👁") }
        if hasReasoning { parts.append("🧠") }
        if hasTools { parts.append("🔧") }
        return parts.joined(separator: " ")
    }

    /// Label for the dropdown row: name + badges.
    var menuLabel: String {
        badges.isEmpty ? name : "\(name)   \(badges)"
    }
}

enum OpenCodeModelCatalog {

    /// Fetches and flattens all provider models from the server's /config/providers.
    /// Sorted by provider then model name. Returns [] on any parse failure.
    static func fetch(baseURL: URL) async throws -> [OpenCodeModelInfo] {
        let url = baseURL
            .appendingPathComponent("config")
            .appendingPathComponent("providers")

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "OpenCodeModelCatalog", code: code,
                          userInfo: [NSLocalizedDescriptionKey: "GET /config/providers failed (\(code))"])
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let providers = json["providers"] as? [[String: Any]] else {
            return []
        }

        var results: [OpenCodeModelInfo] = []
        for provider in providers {
            guard let providerID = provider["id"] as? String,
                  let models = provider["models"] as? [String: Any] else { continue }
            for (modelID, rawModel) in models {
                guard let model = rawModel as? [String: Any] else { continue }
                let name = (model["name"] as? String) ?? modelID
                let caps = model["capabilities"] as? [String: Any]
                let input = caps?["input"] as? [String: Any]
                let hasVision = (input?["image"] as? Bool) ?? false
                let hasReasoning = (caps?["reasoning"] as? Bool) ?? false
                let hasTools = (caps?["toolcall"] as? Bool) ?? false
                results.append(OpenCodeModelInfo(
                    providerID: providerID, modelID: modelID, name: name,
                    hasVision: hasVision, hasReasoning: hasReasoning, hasTools: hasTools
                ))
            }
        }
        return results.sorted {
            ($0.providerID.lowercased(), $0.name.lowercased())
                < ($1.providerID.lowercased(), $1.name.lowercased())
        }
    }
}
