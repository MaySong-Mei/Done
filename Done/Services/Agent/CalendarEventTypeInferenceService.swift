import Foundation

enum CalendarEventTypeSuggestionSource: String, Codable, Equatable {
    case local
    case llm
}

struct CalendarEventTypeSuggestion: Equatable {
    var typeTitle: String
    var confidence: Double
    var source: CalendarEventTypeSuggestionSource
}

protocol AgenticCalendarTypeSuggestionGenerating {
    func generateTypeSuggestion(
        rawText: String,
        availableTypes: [String]
    ) async throws -> AgenticCalendarTypeSuggestionResult
}

extension AgenticCalendarIntakeService: AgenticCalendarTypeSuggestionGenerating { }

func calendarShouldRunPostSaveTypeSuggestion(
    isEnabled: Bool,
    didExplicitlySelectType: Bool
) -> Bool {
    isEnabled && !didExplicitlySelectType
}

func calendarTypeSuggestionRawText(
    title: String,
    note: String
) -> String {
    let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)

    switch (trimmedTitle.isEmpty, trimmedNote.isEmpty) {
    case (false, false):
        return "\(trimmedTitle)\n\(trimmedNote)"
    case (false, true):
        return trimmedTitle
    case (true, false):
        return trimmedNote
    case (true, true):
        return ""
    }
}

func calendarNormalizedTypeSuggestionText(_ text: String) -> String {
    text
        .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        .lowercased()
        .components(separatedBy: CharacterSet.alphanumerics.inverted)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
}

func calendarTypeSuggestionTokens(_ normalizedText: String) -> [String] {
    normalizedText
        .components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
}

func calendarPrefixTokenMatchCount(
    queryTokens: Set<String>,
    candidateTokens: Set<String>,
    minPrefixLength: Int = 2
) -> Int {
    queryTokens.reduce(into: 0) { count, queryToken in
        guard queryToken.count >= minPrefixLength else { return }
        if candidateTokens.contains(where: { candidateToken in
            candidateToken.hasPrefix(queryToken) || queryToken.hasPrefix(candidateToken)
        }) {
            count += 1
        }
    }
}

func calendarResolvedAvailableTypeTitle(
    _ candidate: String,
    availableTypes: [String]
) -> String? {
    let normalizedCandidate = EventTypeTemplateStore.normalizedTitle(candidate)
    guard !normalizedCandidate.isEmpty else { return nil }

    for availableType in availableTypes {
        if EventTypeTemplateStore.normalizedTitle(availableType) == normalizedCandidate {
            return availableType
        }
    }

    return nil
}

func calendarHistoricalTypeSuggestion(
    rawText: String,
    availableTypes: [String],
    events: [Event]
) -> CalendarEventTypeSuggestion? {
    let normalizedText = calendarNormalizedTypeSuggestionText(rawText)
    guard !normalizedText.isEmpty else { return nil }

    let queryTokens = Set(calendarTypeSuggestionTokens(normalizedText))
    guard !queryTokens.isEmpty else { return nil }

    var scoreByType: [String: Double] = [:]
    var bestSingleScoreByType: [String: Double] = [:]

    for event in events {
        guard let resolvedTypeTitle = calendarResolvedAvailableTypeTitle(
            event.type,
            availableTypes: availableTypes
        ) else { continue }

        let normalizedTitle = calendarNormalizedTypeSuggestionText(event.title)
        let normalizedEventText = calendarNormalizedTypeSuggestionText(
            calendarTypeSuggestionRawText(title: event.title, note: event.note)
        )
        guard !normalizedEventText.isEmpty else { continue }

        let titleTokens = Set(calendarTypeSuggestionTokens(normalizedTitle))
        let eventTokens = Set(calendarTypeSuggestionTokens(normalizedEventText))

        var score: Double = 0

        if normalizedText == normalizedTitle || normalizedText == normalizedEventText {
            score = 0.99
        }

        if !normalizedTitle.isEmpty {
            if normalizedText.contains(normalizedTitle) || normalizedTitle.contains(normalizedText) {
                score = max(score, normalizedText == normalizedTitle ? 0.99 : 0.9)
            }
            if normalizedText.count >= 2 && normalizedTitle.hasPrefix(normalizedText) {
                score = max(score, normalizedText.count >= 4 ? 0.9 : 0.8)
            }

            let titleOverlapCount = titleTokens.intersection(queryTokens).count
            if titleOverlapCount > 0 {
                let coverage = Double(titleOverlapCount) / Double(titleTokens.count)
                let precision = Double(titleOverlapCount) / Double(queryTokens.count)
                score = max(score, 0.58 + (coverage * 0.22) + (precision * 0.15))
                if titleOverlapCount == titleTokens.count && titleTokens.count >= 2 {
                    score = max(score, 0.89)
                }
            }

            let titlePrefixMatchCount = calendarPrefixTokenMatchCount(
                queryTokens: queryTokens,
                candidateTokens: titleTokens
            )
            if titlePrefixMatchCount > 0 {
                let coverage = Double(titlePrefixMatchCount) / Double(max(titleTokens.count, 1))
                let precision = Double(titlePrefixMatchCount) / Double(max(queryTokens.count, 1))
                score = max(score, 0.6 + (coverage * 0.18) + (precision * 0.15))
                if titlePrefixMatchCount == queryTokens.count && queryTokens.count >= 2 {
                    score = max(score, 0.83)
                }
            }
        }

        let eventOverlapCount = eventTokens.intersection(queryTokens).count
        if eventOverlapCount > 0 {
            let coverage = Double(eventOverlapCount) / Double(eventTokens.count)
            let precision = Double(eventOverlapCount) / Double(queryTokens.count)
            score = max(score, 0.52 + (coverage * 0.18) + (precision * 0.14))
            if eventOverlapCount >= 2 && coverage >= 0.5 {
                score = max(score, 0.82)
            }
        }

        let eventPrefixMatchCount = calendarPrefixTokenMatchCount(
            queryTokens: queryTokens,
            candidateTokens: eventTokens
        )
        if eventPrefixMatchCount > 0 {
            let coverage = Double(eventPrefixMatchCount) / Double(max(eventTokens.count, 1))
            let precision = Double(eventPrefixMatchCount) / Double(max(queryTokens.count, 1))
            score = max(score, 0.56 + (coverage * 0.16) + (precision * 0.13))
            if eventPrefixMatchCount == queryTokens.count && queryTokens.count >= 2 {
                score = max(score, 0.79)
            }
        }

        guard score >= 0.72 else { continue }

        scoreByType[resolvedTypeTitle, default: 0] += score
        bestSingleScoreByType[resolvedTypeTitle] = max(
            bestSingleScoreByType[resolvedTypeTitle] ?? 0,
            score
        )
    }

    var bestTypeTitle: String?
    var bestAggregateScore: Double = 0
    var bestSingleScore: Double = 0

    for availableType in availableTypes {
        let aggregateScore = scoreByType[availableType] ?? 0
        let singleScore = bestSingleScoreByType[availableType] ?? 0
        guard aggregateScore > 0 else { continue }

        if aggregateScore > bestAggregateScore ||
            (aggregateScore == bestAggregateScore && singleScore > bestSingleScore) {
            bestTypeTitle = availableType
            bestAggregateScore = aggregateScore
            bestSingleScore = singleScore
        }
    }

    guard let bestTypeTitle else { return nil }

    let confidence = min(
        0.97,
        bestSingleScore + min(max(bestAggregateScore - bestSingleScore, 0) * 0.08, 0.06)
    )

    return CalendarEventTypeSuggestion(
        typeTitle: bestTypeTitle,
        confidence: confidence,
        source: .local
    )
}

func calendarKeywordTypeSuggestion(
    rawText: String,
    availableTypes: [String]
) -> CalendarEventTypeSuggestion? {
    let normalizedText = calendarNormalizedTypeSuggestionText(rawText)
    let tokens = Set(calendarTypeSuggestionTokens(normalizedText))

    var bestSuggestion: CalendarEventTypeSuggestion?

    for availableType in availableTypes {
        let normalizedType = EventTypeTemplateStore.normalizedTitle(availableType)
        guard !normalizedType.isEmpty else { continue }

        var bestScore: Double = 0
        let typeTokens = normalizedType
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }

        if normalizedType.count >= 3 && normalizedText.contains(normalizedType) {
            bestScore = max(bestScore, 0.95)
        }
        if normalizedText.count >= 2 && normalizedType.hasPrefix(normalizedText) {
            bestScore = max(bestScore, normalizedText.count >= 4 ? 0.9 : 0.8)
        }
        if !typeTokens.isEmpty && typeTokens.allSatisfy(tokens.contains) {
            bestScore = max(bestScore, typeTokens.count > 1 ? 0.9 : 0.86)
        }
        let typePrefixMatchCount = calendarPrefixTokenMatchCount(
            queryTokens: tokens,
            candidateTokens: Set(typeTokens)
        )
        if typePrefixMatchCount > 0 {
            let coverage = Double(typePrefixMatchCount) / Double(max(typeTokens.count, 1))
            let precision = Double(typePrefixMatchCount) / Double(max(tokens.count, 1))
            bestScore = max(bestScore, 0.62 + (coverage * 0.15) + (precision * 0.12))
        }

        for keyword in calendarLocalTypeSuggestionKeywords(for: normalizedType) {
            if keyword.contains(" ") {
                if normalizedText.contains(keyword) {
                    bestScore = max(bestScore, 0.84)
                }
                if normalizedText.count >= 2 && keyword.hasPrefix(normalizedText) {
                    bestScore = max(bestScore, normalizedText.count >= 4 ? 0.84 : 0.76)
                }
                continue
            }
            if tokens.contains(keyword) {
                bestScore = max(bestScore, 0.84)
            } else if tokens.contains(where: { token in
                token.count >= 2 && (keyword.hasPrefix(token) || token.hasPrefix(keyword))
            }) {
                bestScore = max(bestScore, 0.76)
            }
        }

        guard bestScore > 0 else { continue }
        let candidate = CalendarEventTypeSuggestion(
            typeTitle: availableType,
            confidence: bestScore,
            source: .local
        )
        if let currentBestSuggestion = bestSuggestion {
            if candidate.confidence > currentBestSuggestion.confidence {
                bestSuggestion = candidate
            }
        } else {
            bestSuggestion = candidate
        }
    }

    return bestSuggestion
}

func calendarPreferredLocalTypeSuggestion(
    rawText: String,
    availableTypes: [String],
    historicalEvents: [Event]
) -> CalendarEventTypeSuggestion? {
    let historicalSuggestion = calendarHistoricalTypeSuggestion(
        rawText: rawText,
        availableTypes: availableTypes,
        events: historicalEvents
    )
    let keywordSuggestion = calendarKeywordTypeSuggestion(
        rawText: rawText,
        availableTypes: availableTypes
    )

    switch (historicalSuggestion, keywordSuggestion) {
    case let (historical?, keyword?):
        return historical.confidence >= keyword.confidence ? historical : keyword
    case let (historical?, nil):
        return historical
    case let (nil, keyword?):
        return keyword
    case (nil, nil):
        return nil
    }
}

private func calendarLocalTypeSuggestionKeywords(for normalizedType: String) -> [String] {
    switch normalizedType {
    case "work", "deep work":
        return ["meeting", "sync", "call", "project", "review", "client", "office", "code", "build", "design", "ship"]
    case "study", "reading":
        return ["study", "read", "reading", "course", "lesson", "homework", "practice", "learn", "learning", "language", "research"]
    case "exercise", "workout":
        return ["exercise", "workout", "run", "running", "gym", "walk", "yoga", "training", "swim", "ride", "cycling"]
    case "sleep", "rest":
        return ["sleep", "nap", "rest", "bedtime"]
    default:
        return []
    }
}

@MainActor
final class CalendarEventTypeInferenceService {
    private let typeSuggestionService: any AgenticCalendarTypeSuggestionGenerating
    private let defaults: UserDefaults

    init(
        typeSuggestionService: (any AgenticCalendarTypeSuggestionGenerating)? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.typeSuggestionService = typeSuggestionService ?? AgenticCalendarIntakeService()
        self.defaults = defaults
    }

    func inferTypeIfNeeded(
        for event: Event,
        savedForm: CalendarEventFormData,
        isSuggestionEnabled: Bool,
        store: EventStore
    ) async {
        guard calendarShouldRunPostSaveTypeSuggestion(
            isEnabled: isSuggestionEnabled,
            didExplicitlySelectType: savedForm.didExplicitlySelectType
        ) else { return }

        let availableTypes = EventTypeTemplateStore(defaults: defaults).templates.map(\.title)
        guard !availableTypes.isEmpty else { return }

        let rawText = calendarTypeSuggestionRawText(
            title: savedForm.title,
            note: savedForm.note
        )
        guard !rawText.isEmpty else { return }

        if let localSuggestion = calendarPreferredLocalTypeSuggestion(
            rawText: rawText,
            availableTypes: availableTypes,
            historicalEvents: store.rawCalendarEvents.filter { $0.id != event.id }
        ) {
            await applySuggestion(
                localSuggestion,
                eventID: event.id,
                originalTypeTitle: event.type,
                store: store,
                availableTypes: availableTypes
            )
            return
        }

        do {
            let llmSuggestion = try await typeSuggestionService.generateTypeSuggestion(
                rawText: rawText,
                availableTypes: availableTypes
            )
            await applySuggestion(
                CalendarEventTypeSuggestion(
                    typeTitle: llmSuggestion.typeTitle,
                    confidence: llmSuggestion.confidence,
                    source: .llm
                ),
                eventID: event.id,
                originalTypeTitle: event.type,
                store: store,
                availableTypes: availableTypes
            )
        } catch {
            return
        }
    }

    private func applySuggestion(
        _ suggestion: CalendarEventTypeSuggestion,
        eventID: UUID,
        originalTypeTitle: String,
        store: EventStore,
        availableTypes: [String]
    ) async {
        guard let resolvedTypeTitle = calendarResolvedAvailableTypeTitle(
            suggestion.typeTitle,
            availableTypes: availableTypes
        ) else { return }
        guard let current = store.findCalendarEvent(id: eventID) else { return }

        // Skip stale results if the user already changed the type after save.
        guard current.type == originalTypeTitle else { return }

        var updated = current
        updated.type = resolvedTypeTitle
        updated = EventLogTemplateAdvisor(defaults: defaults).applySuggestion(to: updated)
        guard updated != current else { return }

        store.updateCalendarEvent(updated)
    }
}
