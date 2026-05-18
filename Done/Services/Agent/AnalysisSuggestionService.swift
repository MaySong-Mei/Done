//
//  AnalysisSuggestionService.swift
//  Done
//

import Foundation

struct AISuggestion: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    let icon: String
    let suggestedEvent: SuggestedEvent?
}

struct SuggestedEvent {
    let title: String
    let type: String
    let durationMinutes: Int
}

final class AnalysisSuggestionService {

    func generateSuggestions(store: EventStore, viewModel: AnalysisViewModel) async -> [AISuggestion] {
        let provider: any LLMProvider
        do {
            provider = try buildProvider()
        } catch {
            return []
        }

        let summary = buildScheduleSummary(store: store, viewModel: viewModel)

        let prompt = """
        You are a personal schedule coach. Based on the user's schedule data below, provide 2-4 actionable suggestions to improve their productivity, health, or work-life balance.

        \(summary)

        Return ONLY a JSON array. Each element must have:
        - "title": short suggestion title (e.g. "Take a Break")
        - "detail": one sentence explanation
        - "icon": SF Symbol name (e.g. "bed.double.fill", "figure.walk", "cup.and.saucer.fill", "book.fill")
        - "action": "add_event" if you suggest adding a specific event, or null
        - "eventTitle": title for the suggested event (only if action is "add_event")
        - "eventType": type/category for the suggested event (only if action is "add_event")
        - "eventDuration": duration in minutes for the suggested event (only if action is "add_event")

        Return ONLY the JSON array, no other text.
        """

        let request = LLMRequest(
            messages: [LLMMessage(role: .user, content: prompt)],
            tools: [],
            systemPrompt: "You are a schedule analysis assistant. Respond with valid JSON only."
        )

        do {
            let response = try await provider.send(request)
            guard let text = response.content else { return [] }
            return parseSuggestions(text)
        } catch {
            return []
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

    private func buildScheduleSummary(store: EventStore, viewModel: AnalysisViewModel) -> String {
        let allocations = viewModel.typeAllocations(store: store)
        let totalHours = viewModel.totalScheduledHours(store: store)
        let recordRate = viewModel.recordRate(store: store)
        let streak = viewModel.recordStreak(store: store)
        let completionRate = viewModel.completionRate(store: store)
        let activeTasks = viewModel.activeTasksCount(store: store)
        let range = viewModel.dateRange

        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d"

        var lines: [String] = []
        lines.append("Period: \(fmt.string(from: range.start)) – \(fmt.string(from: range.end)) (\(viewModel.period.rawValue))")
        lines.append("Total scheduled hours: \(String(format: "%.1f", totalHours))")
        lines.append("Record rate: \(String(format: "%.0f", recordRate))%")
        lines.append("Streak: \(streak) days")
        lines.append("Completion rate: \(String(format: "%.0f", completionRate))%")
        lines.append("Active tasks: \(activeTasks)")

        if !allocations.isEmpty {
            lines.append("\nHours by type:")
            for alloc in allocations {
                lines.append("  \(alloc.type): \(String(format: "%.1f", alloc.hours))h")
            }
        }

        return lines.joined(separator: "\n")
    }

    private func parseSuggestions(_ text: String) -> [AISuggestion] {
        var jsonString = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = jsonString.range(of: "["),
           let end = jsonString.range(of: "]", options: .backwards) {
            jsonString = String(jsonString[start.lowerBound...end.lowerBound])
        }

        guard let data = jsonString.data(using: .utf8),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }

        return items.compactMap { item -> AISuggestion? in
            guard let title = item["title"] as? String,
                  let detail = item["detail"] as? String,
                  let icon = item["icon"] as? String else { return nil }

            var suggestedEvent: SuggestedEvent?
            if let action = item["action"] as? String, action == "add_event",
               let eventTitle = item["eventTitle"] as? String,
               let eventType = item["eventType"] as? String,
               let eventDuration = item["eventDuration"] as? Int {
                suggestedEvent = SuggestedEvent(
                    title: eventTitle,
                    type: eventType,
                    durationMinutes: eventDuration
                )
            }

            return AISuggestion(
                title: title,
                detail: detail,
                icon: icon,
                suggestedEvent: suggestedEvent
            )
        }
    }
}
