import Foundation

struct EventLogTemplateSuggestion: Equatable {
    var templateID: EventLogTemplateID?
    var confidence: Double
    var source: SuggestedLogTemplateSource
}

final class EventLogTemplatePreferenceStore {
    static let storageKey = "eventLogTemplatePreferences"
    private let defaults: UserDefaults
    private let threshold: Int

    init(defaults: UserDefaults = .standard, threshold: Int = 3) {
        self.defaults = defaults
        self.threshold = threshold
    }

    func preferredTemplate(for normalizedTypeTitle: String) -> EventLogTemplateID? {
        guard !normalizedTypeTitle.isEmpty else { return nil }
        guard let counts = load()[normalizedTypeTitle] else { return nil }
        guard let winner = counts.max(by: { $0.value < $1.value }), winner.value >= threshold else {
            return nil
        }
        return EventLogTemplateID(rawValue: winner.key)
    }

    func recordOverride(
        eventType: String,
        selectedTemplateID: EventLogTemplateID?,
        suggestedTemplateID: EventLogTemplateID?
    ) {
        guard let selectedTemplateID else { return }
        guard selectedTemplateID != suggestedTemplateID else { return }
        let normalizedTypeTitle = EventTypeTemplateStore.normalizedTitle(eventType)
        guard !normalizedTypeTitle.isEmpty else { return }

        var preferences = load()
        var counts = preferences[normalizedTypeTitle] ?? [:]
        counts[selectedTemplateID.rawValue, default: 0] += 1
        preferences[normalizedTypeTitle] = counts
        save(preferences)
    }

    private func load() -> [String: [String: Int]] {
        guard let data = defaults.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([String: [String: Int]].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private func save(_ preferences: [String: [String: Int]]) {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

struct EventLogTemplateAdvisor {
    private let preferenceStore: EventLogTemplatePreferenceStore

    init(defaults: UserDefaults = .standard) {
        self.preferenceStore = EventLogTemplatePreferenceStore(defaults: defaults)
    }

    func suggestion(for event: Event) -> EventLogTemplateSuggestion {
        let normalizedType = EventTypeTemplateStore.normalizedTitle(event.type)
        if let preferred = preferenceStore.preferredTemplate(for: normalizedType) {
            return EventLogTemplateSuggestion(templateID: preferred, confidence: 0.92, source: .heuristic)
        }

        let haystack = [
            event.title,
            event.type,
            event.location
        ]
        .joined(separator: " ")
        .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        .lowercased()

        let matches: [(EventLogTemplateID, [String], Double)] = [
            (.meeting, ["meeting", "sync", "1:1", "call", "review"], 0.82),
            (.workout, ["workout", "run", "gym", "walk", "yoga"], 0.8),
            (.studySession, ["study", "read", "course", "practice", "lesson", "language"], 0.78),
            (.personalCare, ["sleep", "rest", "meal", "doctor", "meditation"], 0.76),
            (.deepWork, ["write", "build", "design", "code", "plan", "focus"], 0.74)
        ]

        for match in matches {
            if match.1.contains(where: { haystack.contains($0) }) {
                return EventLogTemplateSuggestion(templateID: match.0, confidence: match.2, source: .heuristic)
            }
        }

        return EventLogTemplateSuggestion(templateID: nil, confidence: 0, source: .heuristic)
    }

    func applySuggestion(to event: Event) -> Event {
        let suggestion = suggestion(for: event)
        var updated = event
        updated.suggestedLogTemplateID = suggestion.templateID?.rawValue
        updated.suggestedLogTemplateConfidence = suggestion.templateID == nil ? nil : suggestion.confidence
        updated.suggestedLogTemplateUpdatedAt = suggestion.templateID == nil ? nil : Date()
        updated.suggestedLogTemplateSource = suggestion.templateID == nil ? nil : suggestion.source
        return updated
    }

    func recordOverride(
        eventType: String,
        selectedTemplateID: EventLogTemplateID?,
        suggestedTemplateID: EventLogTemplateID?
    ) {
        preferenceStore.recordOverride(
            eventType: eventType,
            selectedTemplateID: selectedTemplateID,
            suggestedTemplateID: suggestedTemplateID
        )
    }
}
