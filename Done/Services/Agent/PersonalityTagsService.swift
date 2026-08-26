//
//  PersonalityTagsService.swift
//  Done
//
//  Generates a warm, positive "personality profile" (an MBTI-style persona
//  headline + trait tags + a short description) from the user's activity
//  records via the configured LLM. The result is cached in UserDefaults and
//  only regenerated on explicit refresh — it costs tokens, so it must never
//  run per render.
//

import Foundation

/// The cached personality result. `generatedAt` lets the UI show freshness.
struct PersonalityProfile: Codable, Equatable {
    var headline: String
    var summary: String
    var tags: [String]
    var generatedAt: Date
    /// Language the profile was generated in (`AppLanguage.rawValue`). Optional
    /// for backward compatibility with caches written before this field — a nil
    /// value is treated as "unknown" and triggers regeneration on display.
    var language: String?
}

final class PersonalityTagsService {

    enum GenerationError: Error {
        case notConfigured
        case emptyResponse
        case parseFailed
    }

    /// Whether an LLM API key is configured (the feature requires AI).
    static var isConfigured: Bool {
        !(UserDefaults.standard.string(forKey: AppSettingsKeys.agentAPIKey) ?? "").isEmpty
    }

    func generate(store: EventStore, skillStore: SkillInsightStore) async throws -> PersonalityProfile {
        let provider = try buildProvider()
        let summary = buildUserSummary(store: store, skillStore: skillStore)
        let appLanguage = AppLanguage.current
        let language = appLanguage == .chinese ? "Simplified Chinese" : "English"

        let prompt = """
        You are a warm, perceptive personality coach. Based ONLY on the user's \
        activity data below, describe their POSITIVE personality traits. This is \
        an encouraging, feel-good feature — frame everything kindly and never \
        criticize or point out shortcomings.

        \(summary)

        Write EVERY piece of user-facing text — headline, summary, and every \
        tag — entirely in \(language). Do not mix in any other language. Return \
        ONLY a JSON object with these keys:
        - "headline": a short, evocative persona title, 2-6 words (in \(language))
        - "summary": one or two warm sentences describing them positively
        - "tags": an array of 4 to 6 short positive trait words or phrases

        Return ONLY the JSON object, no other text.
        """

        let request = LLMRequest(
            messages: [LLMMessage(role: .user, content: prompt)],
            tools: [],
            systemPrompt: "You are a positive personality-insights assistant. Respond with valid JSON only.",
            purpose: "personality"
        )

        let response = try await provider.send(request)
        guard let text = response.content, !text.isEmpty else {
            throw GenerationError.emptyResponse
        }
        guard var profile = Self.parse(text) else {
            throw GenerationError.parseFailed
        }
        profile.language = appLanguage.rawValue
        return profile
    }

    // MARK: - Summary reductions

    /// Type-distribution slice of the user summary: projected hours-by-type
    /// (the shared `calendarProjectedTypeHours` reduction) plus the in-window
    /// range count reported as "Total tracked activities". Render-frame for
    /// the same reason as the Me-page hour surfaces (gh#204): a traveled
    /// detached instance's window membership is decided by the instant the
    /// canvas draws it on. Static so tests bind it without a provider key.
    static func typeDistribution(
        events: [Event],
        window: ClosedRange<Date>,
        calendar: Calendar
    ) -> (hoursByType: [String: Double], rangeCount: Int) {
        let hours = calendarProjectedTypeHours(
            events: events,
            window: window,
            calendar: calendar
        )
        var count = 0
        for event in events {
            count += event.renderTimeRanges(calendar: calendar)
                .filter { $0.end >= window.lowerBound && $0.start <= window.upperBound }
                .count
        }
        return (hours, count)
    }

    // MARK: - Private

    private func buildProvider() throws -> any LLMProvider {
        let providerType = UserDefaults.standard.string(forKey: AppSettingsKeys.agentProvider) ?? AppSettingsKeys.agentProviderDefault
        let apiKey = UserDefaults.standard.string(forKey: AppSettingsKeys.agentAPIKey) ?? ""

        guard !apiKey.isEmpty else { throw GenerationError.notConfigured }

        switch providerType {
        case "openai": return OpenAIProvider(apiKey: apiKey)
        case "deepseek": return DeepSeekProvider(apiKey: apiKey)
        default: return ClaudeProvider(apiKey: apiKey)
        }
    }

    /// Condenses the user's recent records (last ~90 days) into a compact,
    /// privacy-conscious summary: type distribution, follow-through, emotional
    /// tone, skills, and a short reflection excerpt.
    private func buildUserSummary(store: EventStore, skillStore: SkillInsightStore) -> String {
        let calendar = Calendar.current
        let now = Date()
        let windowStart = calendar.date(byAdding: .day, value: -90, to: now) ?? now

        var lines: [String] = []

        // Type distribution (hours within window).
        let distribution = Self.typeDistribution(
            events: store.canvasRenderableCalendarEvents,
            window: windowStart...now,
            calendar: calendar
        )
        if !distribution.hoursByType.isEmpty {
            lines.append("Activity hours by type (last 90 days):")
            for (type, hours) in distribution.hoursByType.sorted(by: { $0.value > $1.value }).prefix(6) {
                lines.append("  \(type): \(String(format: "%.0f", hours))h")
            }
        }
        lines.append("Total tracked activities: \(distribution.rangeCount)")

        // Emotions & behaviors from logs (frequency).
        let recentLogs = store.calendarEventLogRecords.filter { $0.occurrenceDate >= windowStart }
        if !recentLogs.isEmpty {
            var emotionCounts: [String: Int] = [:]
            var behaviorCounts: [String: Int] = [:]
            var efforts: [Int] = []
            for log in recentLogs {
                log.emotions.forEach { emotionCounts[$0, default: 0] += 1 }
                log.behaviors.forEach { behaviorCounts[$0, default: 0] += 1 }
                if let e = log.effort { efforts.append(e) }
            }
            lines.append("Activities reflected on: \(recentLogs.count)")
            let topEmotions = emotionCounts.sorted { $0.value > $1.value }.prefix(5).map(\.key)
            if !topEmotions.isEmpty { lines.append("Common feelings: \(topEmotions.joined(separator: ", "))") }
            let topBehaviors = behaviorCounts.sorted { $0.value > $1.value }.prefix(5).map(\.key)
            if !topBehaviors.isEmpty { lines.append("Common behaviors: \(topBehaviors.joined(separator: ", "))") }
            if !efforts.isEmpty {
                lines.append("Average effort: \(String(format: "%.1f", Double(efforts.reduce(0, +)) / Double(efforts.count)))/5")
            }
        }

        // Skills.
        let skills = skillStore.insights
            .filter { $0.date >= windowStart }
            .reduce(into: [String: Double]()) { $0[$1.skillName, default: 0] += $1.points }
        if !skills.isEmpty {
            let top = skills.sorted { $0.value > $1.value }.prefix(6).map(\.key)
            lines.append("Skills practiced: \(top.joined(separator: ", "))")
        }

        // Reflection excerpt (the user's own voice), truncated.
        let reflection = (UserDefaults.standard.string(forKey: AppSettingsKeys.meReflectionLog) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !reflection.isEmpty {
            lines.append("Recent reflection: \"\(String(reflection.prefix(400)))\"")
        }

        if lines.isEmpty {
            lines.append("The user has very little recorded activity yet.")
        }
        return lines.joined(separator: "\n")
    }

    static func parse(_ text: String) -> PersonalityProfile? {
        var jsonString = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Use `end.lowerBound` (the position OF "}"), not upperBound — upperBound
        // is the index *after* "}", which equals endIndex when "}" is the last
        // character and traps a ClosedRange subscript. Guard against an inverted
        // range too (e.g. malformed text where "}" precedes "{").
        if let start = jsonString.range(of: "{"),
           let end = jsonString.range(of: "}", options: .backwards),
           start.lowerBound <= end.lowerBound {
            jsonString = String(jsonString[start.lowerBound...end.lowerBound])
        }
        guard let data = jsonString.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let headline = (obj["headline"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !headline.isEmpty else {
            return nil
        }
        let summary = (obj["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let tags = (obj["tags"] as? [Any])?.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
        return PersonalityProfile(headline: headline, summary: summary, tags: tags, generatedAt: Date())
    }
}
