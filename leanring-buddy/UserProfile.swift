//
//  UserProfile.swift
//  leanring-buddy
//
//  Stores the user's personal context — nickname, goals, and any custom notes —
//  so Claude can personalize every response and understand who it's talking to.
//  Think of it as a user.md file that gets prepended to Claude's system prompt.
//  Persisted to UserDefaults as JSON.
//

import Foundation

struct UserProfile: Codable {
    /// The user's preferred name (e.g. "joce"). Claude uses this to address them.
    var nickname: String

    /// What the user wants to accomplish or get better at (e.g. "get better at
    /// coding, create nice projects, do more with less"). Claude factors these
    /// goals into suggestions and keeps the conversation oriented around them.
    var goals: String

    /// Any other context the user wants Claude to always know — preferred tools,
    /// learning style, current projects, etc.
    var additionalContext: String

    init(nickname: String = "", goals: String = "", additionalContext: String = "") {
        self.nickname = nickname
        self.goals = goals
        self.additionalContext = additionalContext
    }

    /// True when at least one field contains non-whitespace content.
    /// Used to decide whether to inject the profile block into system prompts.
    var hasAnyContent: Bool {
        !nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !goals.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !additionalContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Formats the profile as a block that gets prepended to Claude's system prompt.
    /// Only includes fields that are filled in so the prompt stays clean.
    func buildSystemPromptSection() -> String {
        var lines: [String] = []

        let trimmedNickname = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedGoals = goals.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedContext = additionalContext.trimmingCharacters(in: .whitespacesAndNewlines)

        if !trimmedNickname.isEmpty { lines.append("- name: \(trimmedNickname)") }
        if !trimmedGoals.isEmpty    { lines.append("- goals: \(trimmedGoals)") }
        if !trimmedContext.isEmpty  { lines.append("- additional context: \(trimmedContext)") }

        guard !lines.isEmpty else { return "" }

        return "user profile:\n\(lines.joined(separator: "\n"))\n"
    }

    // MARK: - Persistence

    static func load() -> UserProfile {
        guard let data = UserDefaults.standard.data(forKey: "userProfile"),
              let profile = try? JSONDecoder().decode(UserProfile.self, from: data)
        else { return UserProfile() }
        return profile
    }

    func save() {
        if let encoded = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(encoded, forKey: "userProfile")
        }
    }
}
