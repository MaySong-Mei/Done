//
//  SkillAnalysisService.swift
//  Done
//

import Foundation

func skillAnalysisShouldSkipForAgenticProcessing(_ event: Event) -> Bool {
    guard let phase = event.agenticIntake?.processingPhase else {
        return false
    }
    switch phase {
    case .queued, .analyzing, .failed:
        return true
    case .completed:
        return false
    }
}

final class SkillAnalysisService {
    private let insightStore: SkillInsightStore

    init(insightStore: SkillInsightStore) {
        self.insightStore = insightStore
    }

    func analyzeEvent(_ event: Event) async {
        if skillAnalysisShouldSkipForAgenticProcessing(event) {
            return
        }

        // Skip if already analyzed
        guard !insightStore.isAnalyzed(event.id) else { return }

        // Skip short activities
        let durationMinutes = event.duration / 60
        guard durationMinutes >= 15 else { return }

        // Skip future events — only analyze if end time ≤ now
        if let endTime = event.primaryTimeRange?.end {
            guard endTime <= Date() else { return }
        } else {
            return
        }

        let provider: any LLMProvider
        do {
            provider = try buildProvider()
        } catch {
            // Provider unavailable (e.g. missing API key) — do NOT mark analyzed,
            // so the event is retried once a provider becomes available.
            return
        }

        // Mark analyzed now that we have a provider — avoids duplicate triggers
        // during the async send below.
        insightStore.markAnalyzed(event.id)

        let durationHours = event.duration / 3600
        let pointsStr = String(format: "%.2f", durationHours)
        let noteSnippet = event.note.isEmpty ? "" : "\nNotes: \(String(event.note.prefix(200)))"

        let existingSkills = Set(insightStore.insights.map(\.skillName))
        let skillsContext: String
        if existingSkills.isEmpty {
            skillsContext = ""
        } else {
            let list = existingSkills.sorted().joined(separator: ", ")
            skillsContext = "\nExisting skills in the user's profile: [\(list)]\nPrefer reusing these skill names when applicable. Only create a new skill name if none of the existing ones fit."
        }

        let prompt = """
        Analyze this activity and identify 1-3 skills being practiced or developed.

        Activity title: \(event.title)
        Type/category: \(event.type)
        Duration: \(pointsStr) hours\(noteSnippet)\(skillsContext)

        Return ONLY a JSON array. Each element must have:
        - "skill": short skill name (e.g. "Algorithm Design", "English Listening", "UI/UX Design")
        - "points": number of effective practice hours (sum should roughly equal \(pointsStr))
        - "reasoning": one sentence explaining why this skill applies

        Example: [{"skill": "Algorithm Design", "points": 1.5, "reasoning": "Practicing competitive programming problems builds algorithm design skills."}]

        Return ONLY the JSON array, no other text.
        """

        let request = LLMRequest(
            messages: [LLMMessage(role: .user, content: prompt)],
            tools: [],
            systemPrompt: "You are a skill analysis assistant. Respond with valid JSON only."
        )

        do {
            let response = try await provider.send(request)
            guard let text = response.content else { return }
            try parseAndStore(text, event: event)
        } catch {
            // Silently ignore failures
        }
    }

    func analyzePastEvents(_ events: [Event]) async {
        for event in events {
            await analyzeEvent(event)
        }
    }

    // MARK: - Private

    private func buildProvider() throws -> any LLMProvider {
        let providerType = UserDefaults.standard.string(forKey: AppSettingsKeys.agentProvider) ?? AppSettingsKeys.agentProviderDefault
        let apiKey = UserDefaults.standard.string(forKey: AppSettingsKeys.agentAPIKey) ?? ""

        guard !apiKey.isEmpty else {
            throw LLMError.noAPIKey
        }

        switch providerType {
        case "openai":
            return OpenAIProvider(apiKey: apiKey)
        case "deepseek":
            return DeepSeekProvider(apiKey: apiKey)
        default:
            return ClaudeProvider(apiKey: apiKey)
        }
    }

    private func parseAndStore(_ text: String, event: Event) throws {
        // Extract JSON array from response (handle markdown code blocks)
        var jsonString = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = jsonString.range(of: "["),
           let end = jsonString.range(of: "]", options: .backwards) {
            jsonString = String(jsonString[start.lowerBound...end.lowerBound])
        }

        guard let data = jsonString.data(using: .utf8) else { return }
        guard let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }

        let eventDate = event.primaryTimeRange?.start ?? Date()

        for item in items {
            guard let skill = item["skill"] as? String,
                  let points = item["points"] as? Double,
                  let reasoning = item["reasoning"] as? String else { continue }

            let insight = SkillInsight(
                skillName: skill,
                points: points,
                date: eventDate,
                eventTitle: event.title,
                reasoning: reasoning
            )
            insightStore.add(insight)
        }
    }
}
