//
//  TokenInferenceEngine.swift
//  Done
//

import Foundation
import Combine

enum TokenInferenceMode: String, Codable, Hashable {
    case prediction
    case reconcile
}

enum TokenProjectionPhase: String, Codable, Hashable {
    case predicted
    case reconciled
}

enum TokenDynamicHypothesisCategory: String, Codable, Hashable {
    case worldModel = "world_model"
    case state
    case compressed

    var uiKind: TokenHypothesisKind {
        switch self {
        case .worldModel:
            return .worldModel
        case .state:
            return .state
        case .compressed:
            return .compressed
        }
    }
}

enum TokenMetaHypothesisKind: String, CaseIterable, Codable, Hashable, Identifiable {
    case inputSparse = "input_sparse"
    case testingBehavior = "testing_behavior"
    case contextMissing = "context_missing"
    case oneSidedData = "one_sided_data"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .inputSparse: return "Input Sparse"
        case .testingBehavior: return "Testing Behavior"
        case .contextMissing: return "Context Missing"
        case .oneSidedData: return "One-sided Data"
        }
    }
}

enum TokenHypothesisRecordStatus: String, Codable, Hashable {
    case active
    case weakened
    case pruned
}

enum TokenProjectionBand: String, CaseIterable, Codable, Hashable {
    case downLarge = "down_large"
    case downMedium = "down_medium"
    case downSmall = "down_small"
    case flat
    case upSmall = "up_small"
    case upMedium = "up_medium"
    case upLarge = "up_large"

    var scalar: Double {
        switch self {
        case .downLarge: return -1.0
        case .downMedium: return -0.6
        case .downSmall: return -0.3
        case .flat: return 0
        case .upSmall: return 0.3
        case .upMedium: return 0.6
        case .upLarge: return 1.0
        }
    }
}

enum TokenObservabilityLevel: String, Codable, Hashable {
    case low
    case medium
    case high

    var confidenceValue: Double {
        switch self {
        case .low: return 0.28
        case .medium: return 0.58
        case .high: return 0.84
        }
    }
}

struct TokenProjectionHint: Codable, Hashable {
    var cognitiveToken: TokenProjectionBand
    var physicalCalories: TokenProjectionBand
    var tomorrowToken: TokenProjectionBand
    var tomorrowPhysicalCalories: TokenProjectionBand
    var observability: TokenObservabilityLevel
}

struct TokenDynamicHypothesisRecord: Codable, Hashable, Identifiable {
    var id: String
    var category: TokenDynamicHypothesisCategory
    var statement: String
    var confidence: Double
    var weight: Double
    var windowStart: Date
    var windowEnd: Date
    var relatedOccurrenceKeys: [CalendarOccurrenceKey]
    var rationale: String
    var derivedFromIDs: [String]
    var status: TokenHypothesisRecordStatus
    var updatedAt: Date
}

struct TokenMetaHypothesisRecord: Codable, Hashable, Identifiable {
    var kind: TokenMetaHypothesisKind
    var confidence: Double
    var windowStart: Date
    var windowEnd: Date
    var rationale: String
    var status: TokenHypothesisRecordStatus
    var updatedAt: Date

    var id: String { kind.rawValue }
}

struct TokenOccurrenceProjectionRecord: Codable, Hashable, Identifiable {
    var occurrenceKey: CalendarOccurrenceKey
    var occurrenceID: String?
    var eventID: UUID
    var eventTitle: String
    var typeLabel: String
    var start: Date
    var end: Date
    var phase: TokenProjectionPhase
    var tokenBefore: Double
    var tokenAfter: Double
    var physicalCaloriesBefore: Double
    var physicalCaloriesAfter: Double
    var nextDayToken: Double
    var nextDayPhysicalCalories: Double
    var confidence: Double
    var dimensions: TokenDimensionBreakdown
    var reasoningSummary: String
    var evidence: TokenEvidenceBundle
    var stateTags: [String]
    var dynamicHypothesisIDs: [String]
    var metaHypothesisKinds: [TokenMetaHypothesisKind]
    var inferenceSourceLabel: String
    var abstained: Bool
    var updatedAt: Date

    var id: String {
        let day = Int(occurrenceKey.occurrenceDate.timeIntervalSince1970)
        return "\(occurrenceKey.eventID.uuidString)-\(day)-\(phase.rawValue)"
    }
}

struct TokenInferenceSyncMetadata {
    var usedLLM: Bool
    var sourceLabel: String
    var fallbackReason: String?
}

private struct TokenAnalysisRunPlan {
    var occurrence: CalendarEventOccurrenceContext
    var mode: TokenInferenceMode
}

private struct TokenDeterministicPreview {
    var startingToken: Double
    var startingPhysicalCalories: Double
    var heuristicTokenDelta: Double
    var heuristicPhysicalDelta: Double
    var heuristicTomorrowTokenDelta: Double
    var heuristicTomorrowPhysicalDelta: Double
    var suggestedStateTags: [String]
    var confidence: Double
    var evidence: TokenEvidenceBundle
}

@MainActor
final class TokenInferenceRepository {
    static let shared = TokenInferenceRepository()

    private let defaults: UserDefaults
    private let dynamicKey = "tokenInferenceDynamicHypotheses.v2"
    private let metaKey = "tokenInferenceMetaHypotheses.v2"
    private let projectionKey = "tokenInferenceProjections.v2"
    private let activeDynamicCap = 12

    private var dynamicStorage: [TokenDynamicHypothesisRecord]
    private var metaStorage: [TokenMetaHypothesisRecord]
    private var projectionsStorage: [TokenOccurrenceProjectionRecord]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        dynamicStorage = defaults.codableValue([TokenDynamicHypothesisRecord].self, forKey: dynamicKey) ?? []
        metaStorage = defaults.codableValue([TokenMetaHypothesisRecord].self, forKey: metaKey) ?? []
        projectionsStorage = defaults.codableValue([TokenOccurrenceProjectionRecord].self, forKey: projectionKey) ?? []
    }

    var dynamicHypotheses: [TokenDynamicHypothesisRecord] {
        dynamicStorage.sorted { lhs, rhs in
            if lhs.confidence != rhs.confidence { return lhs.confidence > rhs.confidence }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    var metaHypotheses: [TokenMetaHypothesisRecord] {
        metaStorage.sorted { lhs, rhs in
            if lhs.confidence != rhs.confidence { return lhs.confidence > rhs.confidence }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    func activeDynamicHypotheses(at date: Date) -> [TokenDynamicHypothesisRecord] {
        dynamicStorage.filter {
            $0.status != .pruned && $0.windowStart <= date && $0.windowEnd >= date
        }
    }

    func activeMetaHypotheses(at date: Date) -> [TokenMetaHypothesisRecord] {
        metaStorage.filter {
            $0.status != .pruned && $0.windowStart <= date && $0.windowEnd >= date
        }
    }

    func projections(in range: Range<Date>) -> [TokenOccurrenceProjectionRecord] {
        Dictionary(grouping: projectionsStorage.filter { range.contains($0.start) }, by: \.occurrenceKey)
            .compactMap { _, records in
                records.sorted { lhs, rhs in
                    if phaseRank(lhs.phase) != phaseRank(rhs.phase) {
                        return phaseRank(lhs.phase) > phaseRank(rhs.phase)
                    }
                    return lhs.updatedAt > rhs.updatedAt
                }.first
            }
            .sorted { lhs, rhs in
                if lhs.start != rhs.start { return lhs.start < rhs.start }
                return lhs.updatedAt < rhs.updatedAt
            }
    }

    func projection(for occurrenceKey: CalendarOccurrenceKey, phase: TokenProjectionPhase) -> TokenOccurrenceProjectionRecord? {
        projectionsStorage.first {
            $0.occurrenceKey == occurrenceKey && $0.phase == phase
        }
    }

    func latestProjection(before date: Date) -> TokenOccurrenceProjectionRecord? {
        projectionsStorage
            .filter { $0.end <= date }
            .sorted { lhs, rhs in
                if lhs.end != rhs.end { return lhs.end > rhs.end }
                return lhs.updatedAt > rhs.updatedAt
            }
            .first
    }

    fileprivate func applyDynamicOps(
        _ ops: [TokenDynamicOperationPayload],
        occurrenceKey: CalendarOccurrenceKey
    ) -> [String] {
        guard !ops.isEmpty else { return [] }
        let now = Date()
        var lookup = Dictionary(uniqueKeysWithValues: dynamicStorage.map { ($0.id, $0) })
        var touched: [String] = []

        for op in ops {
            let normalizedID = op.id?.trimmingCharacters(in: .whitespacesAndNewlines)
            let statement = op.statement.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallbackID = "\(op.category.rawValue)-\(normalizedCue(statement))"
            let id = normalizedID?.isEmpty == false ? (normalizedID ?? fallbackID) : fallbackID

            switch op.operation {
            case "prune":
                if var existing = lookup[id] {
                    existing.status = .pruned
                    existing.updatedAt = now
                    lookup[id] = existing
                    touched.append(id)
                }
            default:
                let start = op.windowStart ?? occurrenceKey.occurrenceDate
                let end = op.windowEnd ?? Calendar.current.date(byAdding: .day, value: 3, to: occurrenceKey.occurrenceDate) ?? occurrenceKey.occurrenceDate
                let confidence = min(max(op.confidence, 0), 1)
                let weight = min(max(op.weight, 0), 1)
                var related = lookup[id]?.relatedOccurrenceKeys ?? []
                if !related.contains(occurrenceKey) {
                    related.append(occurrenceKey)
                }
                let record = TokenDynamicHypothesisRecord(
                    id: id,
                    category: op.category,
                    statement: statement.isEmpty ? "This hypothesis is still underspecified." : statement,
                    confidence: confidence,
                    weight: weight,
                    windowStart: min(start, end),
                    windowEnd: max(start, end),
                    relatedOccurrenceKeys: related,
                    rationale: op.rationale ?? "LLM-updated dynamic hypothesis.",
                    derivedFromIDs: op.derivedFromIDs,
                    status: confidence < 0.18 ? .weakened : .active,
                    updatedAt: now
                )
                lookup[id] = record
                touched.append(id)
            }
        }

        dynamicStorage = Array(lookup.values)
        compressAndPruneDynamicHypotheses(referenceDate: occurrenceKey.occurrenceDate)
        saveDynamicHypotheses()
        return Array(Set(touched))
    }

    fileprivate func applyMetaOps(
        _ ops: [TokenMetaOperationPayload],
        occurrenceDate: Date
    ) -> [TokenMetaHypothesisKind] {
        guard !ops.isEmpty else { return [] }
        let now = Date()
        var lookup = Dictionary(uniqueKeysWithValues: metaStorage.map { ($0.kind, $0) })
        var touched: [TokenMetaHypothesisKind] = []

        for op in ops {
            switch op.operation {
            case "prune":
                if var existing = lookup[op.kind] {
                    existing.status = .pruned
                    existing.updatedAt = now
                    lookup[op.kind] = existing
                    touched.append(op.kind)
                }
            default:
                let start = op.windowStart ?? occurrenceDate
                let end = op.windowEnd ?? Calendar.current.date(byAdding: .day, value: 3, to: occurrenceDate) ?? occurrenceDate
                lookup[op.kind] = TokenMetaHypothesisRecord(
                    kind: op.kind,
                    confidence: min(max(op.confidence, 0), 1),
                    windowStart: min(start, end),
                    windowEnd: max(start, end),
                    rationale: op.rationale ?? "Meta hypothesis about observability or input quality.",
                    status: op.confidence < 0.18 ? .weakened : .active,
                    updatedAt: now
                )
                touched.append(op.kind)
            }
        }

        metaStorage = Array(lookup.values)
            .filter { $0.status != .pruned || $0.updatedAt > now.addingTimeInterval(-3600) }
        saveMetaHypotheses()
        return touched
    }

    func upsertProjection(_ record: TokenOccurrenceProjectionRecord) {
        if record.phase == .reconciled {
            projectionsStorage.removeAll {
                $0.occurrenceKey == record.occurrenceKey && $0.phase == .predicted
            }
        }
        if let index = projectionsStorage.firstIndex(where: { $0.id == record.id }) {
            projectionsStorage[index] = record
        } else {
            projectionsStorage.append(record)
        }
        projectionsStorage.sort { lhs, rhs in
            if lhs.start != rhs.start { return lhs.start < rhs.start }
            return lhs.updatedAt < rhs.updatedAt
        }
        saveProjections()
    }

    func invalidatePredictedProjections(after date: Date) {
        projectionsStorage.removeAll {
            $0.phase == .predicted && $0.start > date
        }
        saveProjections()
    }

    private func compressAndPruneDynamicHypotheses(referenceDate: Date) {
        let now = Date()
        let active = dynamicStorage.filter {
            $0.status == .active && $0.windowStart <= referenceDate && $0.windowEnd >= referenceDate
        }
        guard active.count > activeDynamicCap else {
            dynamicStorage.removeAll { $0.category == .compressed && $0.updatedAt < now.addingTimeInterval(-3600) }
            return
        }

        var grouped: [String: [TokenDynamicHypothesisRecord]] = [:]
        for record in active where record.category != .compressed {
            grouped["\(record.category.rawValue)-\(semanticCompressionKey(record.statement))", default: []].append(record)
        }

        var compressedRecords: [TokenDynamicHypothesisRecord] = []
        var idsToWeaken = Set<String>()
        for (_, group) in grouped where group.count > 1 {
            let sorted = group.sorted { lhs, rhs in
                if lhs.confidence != rhs.confidence { return lhs.confidence > rhs.confidence }
                return lhs.updatedAt > rhs.updatedAt
            }
            let representative = sorted.first!
            let derived = sorted.map(\.id)
            let keywords = topMeaningfulTokens(from: group.map(\.statement).joined(separator: " "), limit: 3)
            let statement = keywords.isEmpty
                ? "Merged theme around \(representative.statement)"
                : "Merged theme: \(keywords.joined(separator: ", "))"
            compressedRecords.append(
                TokenDynamicHypothesisRecord(
                    id: "compressed-\(semanticCompressionKey(statement))",
                    category: .compressed,
                    statement: statement,
                    confidence: sorted.map(\.confidence).reduce(0, +) / Double(sorted.count),
                    weight: sorted.map(\.weight).max() ?? representative.weight,
                    windowStart: sorted.map(\.windowStart).min() ?? representative.windowStart,
                    windowEnd: sorted.map(\.windowEnd).max() ?? representative.windowEnd,
                    relatedOccurrenceKeys: Array(Set(sorted.flatMap(\.relatedOccurrenceKeys))),
                    rationale: "Semantically compressed from \(sorted.count) nearby hypotheses.",
                    derivedFromIDs: derived,
                    status: .active,
                    updatedAt: now
                )
            )
            idsToWeaken.formUnion(derived)
        }

        if !compressedRecords.isEmpty {
            dynamicStorage.removeAll { $0.category == .compressed }
            dynamicStorage.append(contentsOf: compressedRecords)
            for index in dynamicStorage.indices where idsToWeaken.contains(dynamicStorage[index].id) {
                dynamicStorage[index].status = .weakened
                dynamicStorage[index].updatedAt = now
            }
        }

        var activeAfterCompression = dynamicStorage.filter {
            $0.status == .active && $0.windowStart <= referenceDate && $0.windowEnd >= referenceDate
        }
        if activeAfterCompression.count > activeDynamicCap {
            let overflow = activeAfterCompression
                .sorted { lhs, rhs in
                    if lhs.confidence != rhs.confidence { return lhs.confidence < rhs.confidence }
                    return lhs.updatedAt < rhs.updatedAt
                }
                .prefix(activeAfterCompression.count - activeDynamicCap)
            let overflowIDs = Set(overflow.map(\.id))
            for index in dynamicStorage.indices where overflowIDs.contains(dynamicStorage[index].id) {
                dynamicStorage[index].status = .pruned
                dynamicStorage[index].updatedAt = now
            }
            activeAfterCompression = dynamicStorage.filter {
                $0.status == .active && $0.windowStart <= referenceDate && $0.windowEnd >= referenceDate
            }
            _ = activeAfterCompression
        }

        dynamicStorage = dynamicStorage.filter { $0.status != .pruned || $0.updatedAt > now.addingTimeInterval(-3600) }
    }

    private func saveDynamicHypotheses() {
        defaults.setCodable(dynamicStorage, forKey: dynamicKey)
    }

    private func saveMetaHypotheses() {
        defaults.setCodable(metaStorage, forKey: metaKey)
    }

    private func saveProjections() {
        defaults.setCodable(projectionsStorage, forKey: projectionKey)
    }

    private func phaseRank(_ phase: TokenProjectionPhase) -> Int {
        switch phase {
        case .predicted: return 0
        case .reconciled: return 1
        }
    }
}

@MainActor
final class TokenInferenceCoordinator {
    private var cancellables: Set<AnyCancellable> = []
    private let service: TokenInferenceService
    private weak var store: EventStore?

    init(store: EventStore, service: TokenInferenceService? = nil) {
        self.store = store
        self.service = service ?? .shared
        bind()
    }

    private func bind() {
        guard let store else { return }

        store.calendarEventRecorded
            .sink { [weak self, weak store] event in
                guard let self, let store else { return }
                Task { await self.service.predict(event: event, store: store) }
            }
            .store(in: &cancellables)

        store.calendarEventLogChanged
            .sink { [weak self, weak store] occurrence in
                guard let self, let store else { return }
                Task { await self.service.reconcile(occurrence: occurrence, store: store) }
            }
            .store(in: &cancellables)

        store.calendarEventFeedbackChanged
            .sink { [weak self, weak store] occurrence in
                guard let self, let store else { return }
                Task { await self.service.reconcile(occurrence: occurrence, store: store) }
            }
            .store(in: &cancellables)
    }
}

@MainActor
final class TokenInferenceService {
    static let shared = TokenInferenceService()

    static let bootstrapSourceLabel = "Rules Bootstrap"

    private let repository = TokenInferenceRepository.shared
    private let calculator = TokenDeterministicCalculator()
    private let calendar = Calendar.current
    private let predictionHorizonDays = 14

    func syncForAnalysis(
        store: EventStore,
        dateRange: (start: Date, end: Date),
        period: AnalysisPeriod
    ) async -> TokenInferenceSyncMetadata {
        let plans = analysisRunPlans(store: store, dateRange: dateRange)
        bootstrapMissingProjections(for: plans, store: store)

        let providerBundle: ProviderBundle
        do {
            providerBundle = try buildProvider()
        } catch {
            let rangeProjections = repository.projections(in: dateRange.start..<dateRange.end)
            return TokenInferenceSyncMetadata(
                usedLLM: false,
                sourceLabel: rangeProjections.last?.inferenceSourceLabel ?? "Unavailable",
                fallbackReason: rangeProjections.isEmpty ? error.localizedDescription : nil
            )
        }

        var didUseLLM = false
        for plan in plans {
            let occurrenceKey = resolveOccurrenceKey(for: plan.occurrence, store: store)
            let phase: TokenProjectionPhase = plan.mode == .prediction ? .predicted : .reconciled
            if let existing = repository.projection(for: occurrenceKey, phase: phase),
               existing.inferenceSourceLabel != Self.bootstrapSourceLabel {
                continue
            }
            if await run(mode: plan.mode, occurrence: plan.occurrence, store: store, providerBundle: providerBundle) {
                didUseLLM = true
            }
        }

        let rangeProjections = repository.projections(in: dateRange.start..<dateRange.end)
        return TokenInferenceSyncMetadata(
            usedLLM: didUseLLM,
            sourceLabel: didUseLLM ? providerBundle.label : (rangeProjections.last?.inferenceSourceLabel ?? providerBundle.label),
            fallbackReason: rangeProjections.isEmpty ? "No projections exist in this window yet." : nil
        )
    }

    func predict(event: Event, store: EventStore) async {
        let contexts = upcomingContexts(for: event)
        let providerBundle: ProviderBundle
        do {
            providerBundle = try buildProvider()
        } catch {
            bootstrapMissingProjections(
                for: contexts.map { TokenAnalysisRunPlan(occurrence: $0, mode: .prediction) },
                store: store
            )
            return
        }
        for context in contexts {
            _ = await run(mode: .prediction, occurrence: context, store: store, providerBundle: providerBundle)
        }
    }

    func reconcile(occurrence: CalendarEventOccurrenceContext, store: EventStore) async {
        let providerBundle: ProviderBundle
        do {
            providerBundle = try buildProvider()
        } catch {
            bootstrapMissingProjections(
                for: [TokenAnalysisRunPlan(occurrence: occurrence, mode: .reconcile)],
                store: store
            )
            return
        }
        if await run(mode: .reconcile, occurrence: occurrence, store: store, providerBundle: providerBundle) {
            repository.invalidatePredictedProjections(after: occurrence.occurrenceDate)
        }
    }

    private func run(
        mode: TokenInferenceMode,
        occurrence: CalendarEventOccurrenceContext,
        store: EventStore,
        providerBundle: ProviderBundle
    ) async -> Bool {
        let toolRunner = TokenInferenceToolRunner(
            store: store,
            repository: repository,
            calculator: calculator,
            sourceLabel: providerBundle.label
        )

        var messages = [
            LLMMessage(
                role: .user,
                content: """
                Evaluate one calendar occurrence for Done's hypothesis OS.
                occurrenceEventID: \(occurrence.eventID.uuidString)
                occurrenceDate: \(isoDateString(occurrence.occurrenceDate))
                mode: \(mode.rawValue)

                First call getTokenInferenceContext.
                Then call applyTokenInferenceDecision exactly once.
                Treat the user's event as evidence for competing world-model and state hypotheses.
                Do not output final numeric token or calorie values yourself.
                """
            )
        ]

        for _ in 0..<4 {
            do {
                let response = try await providerBundle.provider.send(
                    LLMRequest(
                        messages: messages,
                        tools: TokenInferenceTool.allDefinitions,
                        systemPrompt: """
                        You are the orchestration layer for Done's hypothesis-driven interpretation engine.
                        The system is not rule-based. The user's events update world explanations.

                        Principles:
                        - World-model hypotheses explain how behavior should currently be interpreted.
                        - State hypotheses describe the user's current mode, such as low energy or near limit.
                        - Meta hypotheses describe observability and input quality.
                        - Resource projections are outputs, not the ontology.
                        - Treat examples like exercise/sleep/work/play as prompt priors, not hard rules.
                        - If evidence is weak, abstain and rely on meta hypotheses.
                        - Keep updates compact and evidence-backed.
                        - Use direct, structural, and historical evidence layers.
                        - Return natural-language hypotheses and qualitative projection hints only.
                        """
                    )
                )

                guard !response.toolCalls.isEmpty else { return false }
                messages.append(
                    LLMMessage(
                        role: .assistant,
                        content: response.content ?? "",
                        toolCalls: response.toolCalls
                    )
                )

                var applied = false
                for call in response.toolCalls {
                    let result = toolRunner.execute(toolName: call.name, arguments: call.arguments)
                    if call.name == TokenInferenceTool.applyTokenInferenceDecision.rawValue {
                        applied = true
                    }
                    messages.append(
                        LLMMessage(
                            role: .tool,
                            content: result,
                            toolCallId: call.id
                        )
                    )
                }

                if applied {
                    return true
                }
            } catch {
                return false
            }
        }
        return false
    }

    private func analysisRunPlans(
        store: EventStore,
        dateRange: (start: Date, end: Date)
    ) -> [TokenAnalysisRunPlan] {
        var plans: [TokenAnalysisRunPlan] = []
        var current = calendar.startOfDay(for: dateRange.start)
        while current < dateRange.end {
            let occurrences = CalendarLayout.occurrencesForDate(store.calendarEvents, date: current, calendar: calendar)
            for occurrence in occurrences {
                let context = CalendarEventOccurrenceContext(
                    eventID: occurrence.event.id,
                    occurrenceDate: current,
                    occurrenceID: occurrence.id,
                    isAllDay: occurrence.event.isAllDay,
                    source: .timelineTap
                )
                let mode: TokenInferenceMode = (store.logRecord(for: context) != nil || store.feedbackRecord(for: context) != nil)
                    ? .reconcile
                    : .prediction
                plans.append(TokenAnalysisRunPlan(occurrence: context, mode: mode))
            }
            current = calendar.date(byAdding: .day, value: 1, to: current) ?? dateRange.end
        }
        return deduplicated(plans)
    }

    private func upcomingContexts(for event: Event) -> [CalendarEventOccurrenceContext] {
        let start = calendar.startOfDay(for: Date())
        let end = calendar.date(byAdding: .day, value: predictionHorizonDays, to: start) ?? start
        var current = start
        var contexts: [CalendarEventOccurrenceContext] = []
        while current < end {
            let occurrences = CalendarLayout.occurrencesForDate([event], date: current, calendar: calendar)
            for occurrence in occurrences where occurrence.range.end >= Date() {
                contexts.append(
                    CalendarEventOccurrenceContext(
                        eventID: occurrence.event.id,
                        occurrenceDate: current,
                        occurrenceID: occurrence.id,
                        isAllDay: occurrence.event.isAllDay,
                        source: .timelineTap
                    )
                )
            }
            current = calendar.date(byAdding: .day, value: 1, to: current) ?? end
        }
        return deduplicated(contexts)
    }

    private func deduplicated(_ plans: [TokenAnalysisRunPlan]) -> [TokenAnalysisRunPlan] {
        var seen = Set<String>()
        return plans.filter { plan in
            let context = plan.occurrence
            let key = "\(context.eventID.uuidString)-\(Int(calendar.startOfDay(for: context.occurrenceDate).timeIntervalSince1970))"
            return seen.insert(key).inserted
        }
    }

    private func deduplicated(_ contexts: [CalendarEventOccurrenceContext]) -> [CalendarEventOccurrenceContext] {
        var seen = Set<String>()
        return contexts.filter { context in
            let key = "\(context.eventID.uuidString)-\(Int(calendar.startOfDay(for: context.occurrenceDate).timeIntervalSince1970))"
            return seen.insert(key).inserted
        }
    }

    private func bootstrapMissingProjections(
        for plans: [TokenAnalysisRunPlan],
        store: EventStore
    ) {
        for plan in plans {
            let occurrenceKey = resolveOccurrenceKey(for: plan.occurrence, store: store)
            let phase: TokenProjectionPhase = plan.mode == .prediction ? .predicted : .reconciled
            guard repository.projection(for: occurrenceKey, phase: phase) == nil,
                  let resolved = resolvedOccurrence(for: plan.occurrence, store: store) else {
                continue
            }

            let preview = calculator.preview(
                occurrence: resolved.occurrence,
                occurrenceDay: resolved.day,
                store: store,
                repository: repository,
                mode: plan.mode
            )

            let projection = calculator.project(
                occurrence: resolved.occurrence,
                occurrenceDay: resolved.day,
                store: store,
                repository: repository,
                mode: plan.mode,
                abstain: false,
                reasoningSummary: bootstrapReasoningSummary(for: plan.mode),
                evidence: preview.evidence,
                stateTags: preview.suggestedStateTags,
                dynamicHypothesisIDs: [],
                metaHypothesisKinds: [],
                projectionHint: nil,
                sourceLabel: Self.bootstrapSourceLabel,
                prior: preview
            )
            repository.upsertProjection(projection)
        }
    }

    private func bootstrapReasoningSummary(for mode: TokenInferenceMode) -> String {
        switch mode {
        case .prediction:
            return "Initialized from the current event window so Analysis is populated before new events trigger the engine."
        case .reconcile:
            return "Initialized from existing event evidence so Analysis is populated before new events trigger the engine."
        }
    }

    private func buildProvider() throws -> ProviderBundle {
        let providerType = UserDefaults.standard.string(forKey: "agentProvider") ?? "claude"
        let apiKey = UserDefaults.standard.string(forKey: "agentAPIKey") ?? ""

        guard !apiKey.isEmpty else {
            throw LLMError.noAPIKey
        }

        switch providerType {
        case "openai":
            return ProviderBundle(provider: OpenAIProvider(apiKey: apiKey), label: "OpenAI + Functions")
        case "deepseek":
            return ProviderBundle(provider: DeepSeekProvider(apiKey: apiKey), label: "DeepSeek + Functions")
        default:
            return ProviderBundle(provider: ClaudeProvider(apiKey: apiKey), label: "Claude + Functions")
        }
    }

    private func resolveOccurrenceKey(for context: CalendarEventOccurrenceContext, store: EventStore) -> CalendarOccurrenceKey {
        let event = store.findCalendarEvent(id: context.eventID) ?? Event(id: context.eventID, title: "", timeRanges: [], type: "")
        return CalendarOccurrenceKey.make(for: event, occurrenceDate: context.occurrenceDate)
    }

    private func resolvedOccurrence(
        for context: CalendarEventOccurrenceContext,
        store: EventStore
    ) -> (event: Event, occurrence: CalendarLayout.EventOccurrence, day: Date)? {
        guard let event = store.findCalendarEvent(id: context.eventID) else { return nil }
        let day = calendar.startOfDay(for: context.occurrenceDate)
        let occurrence = CalendarLayout.occurrencesForDate([event], date: day, calendar: calendar)
            .first {
                CalendarOccurrenceKey.make(for: $0.event, occurrenceDate: day) == CalendarOccurrenceKey.make(for: event, occurrenceDate: day)
            }
        guard let occurrence else { return nil }
        return (event, occurrence, day)
    }
}

private enum TokenInferenceTool: String, CaseIterable {
    case getTokenInferenceContext
    case applyTokenInferenceDecision

    var definition: LLMToolDefinition {
        switch self {
        case .getTokenInferenceContext:
            return LLMToolDefinition(
                name: rawValue,
                description: "Fetch the structured context for one occurrence before making a hypothesis update.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "eventID": ["type": "string"],
                        "occurrenceDate": ["type": "string", "description": "YYYY-MM-DD"],
                        "mode": ["type": "string", "enum": ["prediction", "reconcile"]]
                    ],
                    "required": ["eventID", "occurrenceDate", "mode"]
                ]
            )
        case .applyTokenInferenceDecision:
            return LLMToolDefinition(
                name: rawValue,
                description: "Apply hypothesis updates and a qualitative projection hint for the occurrence.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "eventID": ["type": "string"],
                        "occurrenceDate": ["type": "string", "description": "YYYY-MM-DD"],
                        "mode": ["type": "string", "enum": ["prediction", "reconcile"]],
                        "abstain": ["type": "boolean"],
                        "reasoningSummary": ["type": "string"],
                        "stateTags": ["type": "array", "items": ["type": "string"]],
                        "projectionHint": [
                            "type": "object",
                            "properties": [
                                "cognitiveToken": ["type": "string", "enum": TokenProjectionBand.allCases.map(\.rawValue)],
                                "physicalCalories": ["type": "string", "enum": TokenProjectionBand.allCases.map(\.rawValue)],
                                "tomorrowToken": ["type": "string", "enum": TokenProjectionBand.allCases.map(\.rawValue)],
                                "tomorrowPhysicalCalories": ["type": "string", "enum": TokenProjectionBand.allCases.map(\.rawValue)],
                                "observability": ["type": "string", "enum": ["low", "medium", "high"]]
                            ],
                            "required": ["cognitiveToken", "physicalCalories", "tomorrowToken", "tomorrowPhysicalCalories", "observability"]
                        ],
                        "evidence": [
                            "type": "object",
                            "properties": [
                                "direct": ["type": "array", "items": ["type": "string"]],
                                "structural": ["type": "array", "items": ["type": "string"]],
                                "historical": ["type": "array", "items": ["type": "string"]]
                            ]
                        ],
                        "dynamicOps": [
                            "type": "array",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "operation": ["type": "string", "enum": ["upsert", "prune"]],
                                    "category": ["type": "string", "enum": ["world_model", "state"]],
                                    "id": ["type": "string"],
                                    "statement": ["type": "string"],
                                    "confidence": ["type": "number"],
                                    "weight": ["type": "number"],
                                    "windowStart": ["type": "string"],
                                    "windowEnd": ["type": "string"],
                                    "rationale": ["type": "string"],
                                    "derivedFromIDs": ["type": "array", "items": ["type": "string"]]
                                ],
                                "required": ["operation", "category"]
                            ]
                        ],
                        "metaOps": [
                            "type": "array",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "operation": ["type": "string", "enum": ["upsert", "prune"]],
                                    "kind": ["type": "string", "enum": TokenMetaHypothesisKind.allCases.map(\.rawValue)],
                                    "confidence": ["type": "number"],
                                    "windowStart": ["type": "string"],
                                    "windowEnd": ["type": "string"],
                                    "rationale": ["type": "string"]
                                ],
                                "required": ["operation", "kind"]
                            ]
                        ]
                    ],
                    "required": ["eventID", "occurrenceDate", "mode", "abstain", "reasoningSummary"]
                ]
            )
        }
    }

    static var allDefinitions: [LLMToolDefinition] {
        allCases.map(\.definition)
    }
}

private struct ProviderBundle {
    var provider: any LLMProvider
    var label: String
}

private struct TokenDynamicOperationPayload {
    var operation: String
    var category: TokenDynamicHypothesisCategory
    var id: String?
    var statement: String
    var confidence: Double
    var weight: Double
    var windowStart: Date?
    var windowEnd: Date?
    var rationale: String?
    var derivedFromIDs: [String]
}

private struct TokenMetaOperationPayload {
    var operation: String
    var kind: TokenMetaHypothesisKind
    var confidence: Double
    var windowStart: Date?
    var windowEnd: Date?
    var rationale: String?
}

@MainActor
private struct TokenInferenceToolRunner {
    let store: EventStore
    let repository: TokenInferenceRepository
    let calculator: TokenDeterministicCalculator
    let sourceLabel: String

    func execute(toolName: String, arguments: String) -> String {
        guard let data = arguments.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return jsonResult(success: false, message: "Invalid tool arguments.")
        }

        switch toolName {
        case TokenInferenceTool.getTokenInferenceContext.rawValue:
            return executeGetContext(args: args)
        case TokenInferenceTool.applyTokenInferenceDecision.rawValue:
            return executeApplyDecision(args: args)
        default:
            return jsonResult(success: false, message: "Unknown token inference tool.")
        }
    }

    private func executeGetContext(args: [String: Any]) -> String {
        guard let occurrence = resolveOccurrence(args: args),
              let mode = TokenInferenceMode(rawValue: (args["mode"] as? String) ?? "") else {
            return jsonResult(success: false, message: "Missing occurrence or mode.")
        }

        let occurrenceKey = CalendarOccurrenceKey.make(for: occurrence.event, occurrenceDate: occurrence.day)
        let preview = calculator.preview(
            occurrence: occurrence.occurrence,
            occurrenceDay: occurrence.day,
            store: store,
            repository: repository,
            mode: mode
        )

        let payload = TokenInferenceContextPayload(
            occurrenceKey: occurrenceKey,
            mode: mode,
            eventTitle: occurrence.occurrence.event.title,
            eventType: occurrence.occurrence.event.type,
            eventNote: occurrence.occurrence.event.note,
            start: occurrence.occurrence.range.start,
            end: occurrence.occurrence.range.end,
            currentProjection: repository.projection(for: occurrenceKey, phase: mode == .prediction ? .predicted : .reconciled),
            activeDynamicHypotheses: repository.activeDynamicHypotheses(at: occurrence.occurrence.range.end),
            activeMetaHypotheses: repository.activeMetaHypotheses(at: occurrence.occurrence.range.end),
            preview: TokenInferencePreviewPayload(preview),
            logRecord: store.logRecord(for: occurrence.context),
            feedbackRecord: store.feedbackRecord(for: occurrence.context)
        )

        return jsonEncoded(payload) ?? jsonResult(success: false, message: "Failed to encode token context.")
    }

    private func executeApplyDecision(args: [String: Any]) -> String {
        guard let occurrence = resolveOccurrence(args: args),
              let mode = TokenInferenceMode(rawValue: (args["mode"] as? String) ?? "") else {
            return jsonResult(success: false, message: "Missing occurrence or mode.")
        }

        let abstain = (args["abstain"] as? Bool) ?? false
        let occurrenceKey = CalendarOccurrenceKey.make(for: occurrence.event, occurrenceDate: occurrence.day)
        let dynamicOps = parseDynamicOps(args["dynamicOps"] as? [[String: Any]] ?? [])
        let metaOps = parseMetaOps(args["metaOps"] as? [[String: Any]] ?? [])
        let projectionHint = parseProjectionHint(args["projectionHint"] as? [String: Any])
        let evidence = parseEvidence(args["evidence"] as? [String: Any] ?? [:])
        let stateTags = ((args["stateTags"] as? [String]) ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let appliedDynamicIDs = repository.applyDynamicOps(dynamicOps, occurrenceKey: occurrenceKey)
        let appliedMetaKinds = repository.applyMetaOps(metaOps, occurrenceDate: occurrence.day)

        let preview = calculator.preview(
            occurrence: occurrence.occurrence,
            occurrenceDay: occurrence.day,
            store: store,
            repository: repository,
            mode: mode
        )

        let projection = calculator.project(
            occurrence: occurrence.occurrence,
            occurrenceDay: occurrence.day,
            store: store,
            repository: repository,
            mode: mode,
            abstain: abstain,
            reasoningSummary: (args["reasoningSummary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            evidence: evidence,
            stateTags: stateTags,
            dynamicHypothesisIDs: appliedDynamicIDs,
            metaHypothesisKinds: appliedMetaKinds,
            projectionHint: projectionHint,
            sourceLabel: sourceLabel,
            prior: preview
        )

        repository.upsertProjection(projection)
        return jsonEncoded(projection) ?? jsonResult(success: false, message: "Failed to encode projection.")
    }

    private func resolveOccurrence(args: [String: Any]) -> (event: Event, occurrence: CalendarLayout.EventOccurrence, day: Date, context: CalendarEventOccurrenceContext)? {
        guard let eventIDString = args["eventID"] as? String,
              let eventID = UUID(uuidString: eventIDString),
              let dateString = args["occurrenceDate"] as? String,
              let occurrenceDate = dayOnlyFormatter.date(from: dateString),
              let event = store.findCalendarEvent(id: eventID) else {
            return nil
        }

        let day = Calendar.current.startOfDay(for: occurrenceDate)
        let occurrence = CalendarLayout.occurrencesForDate([event], date: day, calendar: .current)
            .first { CalendarOccurrenceKey.make(for: $0.event, occurrenceDate: day) == CalendarOccurrenceKey.make(for: event, occurrenceDate: day) }
        guard let occurrence else { return nil }

        let context = CalendarEventOccurrenceContext(
            eventID: occurrence.event.id,
            occurrenceDate: day,
            occurrenceID: occurrence.id,
            isAllDay: occurrence.event.isAllDay,
            source: .timelineTap
        )
        return (event, occurrence, day, context)
    }

    private func parseDynamicOps(_ items: [[String: Any]]) -> [TokenDynamicOperationPayload] {
        items.compactMap { item in
            guard let operation = item["operation"] as? String,
                  let categoryString = item["category"] as? String,
                  let category = TokenDynamicHypothesisCategory(rawValue: categoryString) else {
                return nil
            }
            return TokenDynamicOperationPayload(
                operation: operation,
                category: category,
                id: item["id"] as? String,
                statement: item["statement"] as? String ?? "",
                confidence: item["confidence"] as? Double ?? 0.35,
                weight: item["weight"] as? Double ?? 0.35,
                windowStart: parseISODate(item["windowStart"] as? String),
                windowEnd: parseISODate(item["windowEnd"] as? String),
                rationale: item["rationale"] as? String,
                derivedFromIDs: item["derivedFromIDs"] as? [String] ?? []
            )
        }
    }

    private func parseMetaOps(_ items: [[String: Any]]) -> [TokenMetaOperationPayload] {
        items.compactMap { item in
            guard let operation = item["operation"] as? String,
                  let kindString = item["kind"] as? String,
                  let kind = TokenMetaHypothesisKind(rawValue: kindString) else {
                return nil
            }
            return TokenMetaOperationPayload(
                operation: operation,
                kind: kind,
                confidence: item["confidence"] as? Double ?? 0.35,
                windowStart: parseISODate(item["windowStart"] as? String),
                windowEnd: parseISODate(item["windowEnd"] as? String),
                rationale: item["rationale"] as? String
            )
        }
    }

    private func parseProjectionHint(_ payload: [String: Any]?) -> TokenProjectionHint? {
        guard let payload,
              let cognitive = payload["cognitiveToken"] as? String,
              let physical = payload["physicalCalories"] as? String,
              let tomorrowToken = payload["tomorrowToken"] as? String,
              let tomorrowPhysical = payload["tomorrowPhysicalCalories"] as? String,
              let observability = payload["observability"] as? String,
              let cognitiveBand = TokenProjectionBand(rawValue: cognitive),
              let physicalBand = TokenProjectionBand(rawValue: physical),
              let tomorrowTokenBand = TokenProjectionBand(rawValue: tomorrowToken),
              let tomorrowPhysicalBand = TokenProjectionBand(rawValue: tomorrowPhysical),
              let observabilityLevel = TokenObservabilityLevel(rawValue: observability) else {
            return nil
        }
        return TokenProjectionHint(
            cognitiveToken: cognitiveBand,
            physicalCalories: physicalBand,
            tomorrowToken: tomorrowTokenBand,
            tomorrowPhysicalCalories: tomorrowPhysicalBand,
            observability: observabilityLevel
        )
    }

    private func parseEvidence(_ payload: [String: Any]) -> TokenEvidenceBundle {
        TokenEvidenceBundle(
            direct: payload["direct"] as? [String] ?? [],
            structural: payload["structural"] as? [String] ?? [],
            historical: payload["historical"] as? [String] ?? []
        )
    }
}

private struct TokenInferenceContextPayload: Codable {
    var occurrenceKey: CalendarOccurrenceKey
    var mode: TokenInferenceMode
    var eventTitle: String
    var eventType: String
    var eventNote: String
    var start: Date
    var end: Date
    var currentProjection: TokenOccurrenceProjectionRecord?
    var activeDynamicHypotheses: [TokenDynamicHypothesisRecord]
    var activeMetaHypotheses: [TokenMetaHypothesisRecord]
    var preview: TokenInferencePreviewPayload
    var logRecord: CalendarEventLogRecord?
    var feedbackRecord: CalendarEventFeedbackRecord?
}

private struct TokenInferencePreviewPayload: Codable {
    var startingToken: Double
    var startingPhysicalCalories: Double
    var heuristicTokenDelta: Double
    var heuristicPhysicalDelta: Double
    var heuristicTomorrowTokenDelta: Double
    var heuristicTomorrowPhysicalDelta: Double
    var suggestedStateTags: [String]
    var confidence: Double
    var evidence: TokenEvidenceBundle

    init(_ preview: TokenDeterministicPreview) {
        startingToken = preview.startingToken
        startingPhysicalCalories = preview.startingPhysicalCalories
        heuristicTokenDelta = preview.heuristicTokenDelta
        heuristicPhysicalDelta = preview.heuristicPhysicalDelta
        heuristicTomorrowTokenDelta = preview.heuristicTomorrowTokenDelta
        heuristicTomorrowPhysicalDelta = preview.heuristicTomorrowPhysicalDelta
        suggestedStateTags = preview.suggestedStateTags
        confidence = preview.confidence
        evidence = preview.evidence
    }
}

private struct TokenDeterministicCalculator {
    private let calendar = Calendar.current

    func preview(
        occurrence: CalendarLayout.EventOccurrence,
        occurrenceDay: Date,
        store: EventStore,
        repository: TokenInferenceRepository,
        mode: TokenInferenceMode
    ) -> TokenDeterministicPreview {
        let context = CalendarEventOccurrenceContext(
            eventID: occurrence.event.id,
            occurrenceDate: occurrenceDay,
            occurrenceID: occurrence.id,
            isAllDay: occurrence.event.isAllDay,
            source: .timelineTap
        )

        let log = store.logRecord(for: context)
        let feedback = store.feedbackRecord(for: context)
        let activeDynamic = repository.activeDynamicHypotheses(at: occurrence.range.end)
        let activeMeta = repository.activeMetaHypotheses(at: occurrence.range.end)

        let title = occurrence.event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = occurrence.event.note.trimmingCharacters(in: .whitespacesAndNewlines)
        let type = occurrence.event.type.trimmingCharacters(in: .whitespacesAndNewlines)
        let combinedText = [title, note, type, log?.summary ?? "", log?.note ?? "", feedback?.selfNote ?? ""]
            .joined(separator: " ")
            .lowercased()

        let durationMinutes = Double(log?.actualDurationMinutes ?? max(1, Int(occurrence.range.end.timeIntervalSince(occurrence.range.start) / 60)))
        let durationHours = max(durationMinutes / 60, occurrence.event.isAllDay ? 8 : 0.25)

        var heuristicTokenDelta = 0.0
        var heuristicPhysicalDelta = 0.0
        var heuristicTomorrowTokenDelta = 0.0
        var heuristicTomorrowPhysicalDelta = 0.0
        var suggestedStateTags: [String] = []

        var directEvidence: [String] = []
        var structuralEvidence: [String] = []
        var historicalEvidence: [String] = []
        var confidence = 0.22

        if !title.isEmpty {
            directEvidence.append("Event title: \(title)")
            confidence += 0.08
        }
        if !type.isEmpty {
            directEvidence.append("Event type: \(type)")
            confidence += 0.04
        }
        if !note.isEmpty {
            directEvidence.append("Event note adds semantic context.")
            confidence += 0.04
        }
        if let log {
            directEvidence.append("Event log exists with completion/context details.")
            confidence += 0.18
            if !log.summary.isEmpty {
                directEvidence.append("Log summary: \(log.summary)")
            }
        }
        if let feedback {
            directEvidence.append("Self feedback exists for this occurrence.")
            confidence += 0.12
            if !feedback.selfNote.isEmpty {
                directEvidence.append("Feedback note: \(feedback.selfNote)")
            }
        }

        structuralEvidence.append("Duration: \(Int(durationMinutes.rounded())) minutes")
        if occurrence.event.isInterrupt {
            structuralEvidence.append("The event is marked as an interrupt.")
        }
        if occurrence.range.end < Date() && log == nil && feedback == nil {
            structuralEvidence.append("The event already ended but no completion log exists yet.")
        }

        // Lightweight bootstrap prior only. These are not the main ontology.
        if containsAny(combinedText, matches: ["sleep", "nap", "bed", "rest", "recover"]) {
            heuristicTokenDelta += 14
            heuristicPhysicalDelta += 360
            heuristicTomorrowTokenDelta += 18
            heuristicTomorrowPhysicalDelta += 460
            suggestedStateTags.append("Recovering")
        }
        if containsAny(combinedText, matches: ["shower", "bath", "wash", "hot bath"]) {
            heuristicTokenDelta += 8
            heuristicPhysicalDelta += 80
            suggestedStateTags.append("Resetting")
        }
        if containsAny(combinedText, matches: ["exercise", "run", "workout", "gym", "yoga", "cycle", "swim"]) {
            heuristicTokenDelta += 6
            heuristicPhysicalDelta -= 260
            heuristicTomorrowTokenDelta += 8
            heuristicTomorrowPhysicalDelta += 120
            suggestedStateTags.append("Physically Spent")
        }
        if containsAny(combinedText, matches: ["tv", "show", "movie", "watch", "game", "gaming", "fun", "play"]) {
            heuristicTokenDelta += 7
            heuristicPhysicalDelta += 120
            suggestedStateTags.append("Unwinding")
        }
        if containsAny(combinedText, matches: ["trip", "outing", "travel", "walk around", "hangout", "social", "dinner out"]) {
            heuristicTokenDelta += 6
            heuristicPhysicalDelta -= 140
            suggestedStateTags.append("Out and About")
        }
        if containsAny(combinedText, matches: ["work", "code", "coding", "meeting", "study", "research", "design", "writing", "write", "plan"]) {
            heuristicTokenDelta -= 10
            heuristicPhysicalDelta -= 70
            heuristicTomorrowTokenDelta -= 4
        }
        if containsAny(combinedText, matches: ["clean", "chores", "moving", "搬家", "labor", "manual", "errand"]) {
            heuristicPhysicalDelta -= 220
            heuristicTokenDelta -= 3
            suggestedStateTags.append("Physically Loaded")
        }

        if let effort = log?.effort ?? feedback?.effort {
            heuristicTokenDelta -= Double(effort) * 1.6
            heuristicPhysicalDelta -= Double(max(0, effort - 2)) * 35
            structuralEvidence.append("Effort rating: \(effort)/5")
        }

        let emotions = Set((log?.emotions ?? []) + (feedback?.emotions ?? []))
        if emotions.contains(CalendarEmotionTag.tired.rawValue) {
            heuristicTokenDelta -= 5
            heuristicPhysicalDelta -= 120
            suggestedStateTags.append("Low Energy")
        }
        if emotions.contains(CalendarEmotionTag.overwhelmed.rawValue) || emotions.contains(CalendarEmotionTag.stressed.rawValue) {
            heuristicTokenDelta -= 7
            suggestedStateTags.append("Near Limit")
        }
        if emotions.contains(CalendarEmotionTag.calm.rawValue) || emotions.contains(CalendarEmotionTag.energized.rawValue) {
            heuristicTokenDelta += 4
            heuristicPhysicalDelta += 90
        }

        let behaviors = Set((log?.behaviors ?? []) + (feedback?.behaviors ?? []))
        if behaviors.contains(CalendarBehaviorTag.interrupted.rawValue) || behaviors.contains(CalendarBehaviorTag.distracted.rawValue) {
            heuristicTokenDelta -= 5
            suggestedStateTags.append("Fragmented")
        }
        if behaviors.contains(CalendarBehaviorTag.avoidant.rawValue) {
            suggestedStateTags.append("Avoidant")
        }

        if let energyAfter = answerString(fieldID: "energyAfter", record: log) {
            switch energyAfter {
            case "energized":
                heuristicTokenDelta += 8
                heuristicPhysicalDelta += 110
            case "drained":
                heuristicTokenDelta -= 7
                heuristicPhysicalDelta -= 140
                suggestedStateTags.append("Drained")
            default:
                break
            }
        }

        if let careKind = answerString(fieldID: "careKind", record: log) {
            switch careKind {
            case "sleep":
                heuristicTokenDelta += 18
                heuristicPhysicalDelta += 420
                heuristicTomorrowTokenDelta += 16
                heuristicTomorrowPhysicalDelta += 380
            case "rest":
                heuristicTokenDelta += 10
                heuristicPhysicalDelta += 170
            case "reset":
                heuristicTokenDelta += 9
                heuristicPhysicalDelta += 120
            case "meal":
                heuristicTokenDelta += 6
                heuristicPhysicalDelta += 150
            default:
                break
            }
        }

        if let feltBetter = answerString(fieldID: "feltBetterAfter", record: log) {
            switch feltBetter {
            case "yes":
                heuristicTokenDelta += 8
                heuristicPhysicalDelta += 120
            case "partly":
                heuristicTokenDelta += 3
                heuristicPhysicalDelta += 55
            case "no":
                heuristicTokenDelta -= 4
                heuristicPhysicalDelta -= 60
            default:
                break
            }
        }

        let stateAfter = answerStrings(fieldID: "stateAfter", record: log)
        if stateAfter.contains("refreshed") || stateAfter.contains("calm") {
            heuristicTokenDelta += 6
        }
        if stateAfter.contains("tired") || stateAfter.contains("stressed") {
            heuristicTokenDelta -= 6
            suggestedStateTags.append("Low Energy")
        }

        for hypothesis in activeDynamic.prefix(3) {
            historicalEvidence.append(hypothesis.statement)
        }

        var observabilityPenalty = 0.0
        for meta in activeMeta {
            switch meta.kind {
            case .inputSparse:
                observabilityPenalty += meta.confidence * 0.14
            case .contextMissing:
                observabilityPenalty += meta.confidence * 0.18
            case .oneSidedData:
                observabilityPenalty += meta.confidence * 0.12
            case .testingBehavior:
                observabilityPenalty += meta.confidence * 0.28
            }
        }

        if durationHours > 3 {
            structuralEvidence.append("Long duration raises state uncertainty and magnitude.")
        } else if durationHours < 0.5 {
            structuralEvidence.append("Short duration limits the size of any projection move.")
        }

        let startingToken = repository.latestProjection(before: occurrence.range.start)?.tokenAfter
            ?? initialTokenBaseline(before: occurrenceDay, store: store)
        let startingPhysicalCalories = repository.latestProjection(before: occurrence.range.start)?.physicalCaloriesAfter
            ?? initialPhysicalBaseline(before: occurrenceDay, store: store)

        heuristicTokenDelta = min(max(heuristicTokenDelta, -24), 24)
        heuristicPhysicalDelta = min(max(heuristicPhysicalDelta, -650), 650)
        heuristicTomorrowTokenDelta = min(max(heuristicTomorrowTokenDelta, -22), 22)
        heuristicTomorrowPhysicalDelta = min(max(heuristicTomorrowPhysicalDelta, -700), 700)
        confidence = min(max(confidence - observabilityPenalty, 0.08), 0.94)
        suggestedStateTags = normalizedTags(suggestedStateTags)

        return TokenDeterministicPreview(
            startingToken: startingToken,
            startingPhysicalCalories: startingPhysicalCalories,
            heuristicTokenDelta: heuristicTokenDelta,
            heuristicPhysicalDelta: heuristicPhysicalDelta,
            heuristicTomorrowTokenDelta: heuristicTomorrowTokenDelta,
            heuristicTomorrowPhysicalDelta: heuristicTomorrowPhysicalDelta,
            suggestedStateTags: suggestedStateTags,
            confidence: confidence,
            evidence: TokenEvidenceBundle(
                direct: Array(directEvidence.prefix(5)),
                structural: Array(structuralEvidence.prefix(5)),
                historical: Array(historicalEvidence.prefix(4))
            )
        )
    }

    func project(
        occurrence: CalendarLayout.EventOccurrence,
        occurrenceDay: Date,
        store: EventStore,
        repository: TokenInferenceRepository,
        mode: TokenInferenceMode,
        abstain: Bool,
        reasoningSummary: String?,
        evidence: TokenEvidenceBundle,
        stateTags: [String],
        dynamicHypothesisIDs: [String],
        metaHypothesisKinds: [TokenMetaHypothesisKind],
        projectionHint: TokenProjectionHint?,
        sourceLabel: String,
        prior: TokenDeterministicPreview
    ) -> TokenOccurrenceProjectionRecord {
        let durationMinutes = Double(max(1, Int(occurrence.range.end.timeIntervalSince(occurrence.range.start) / 60)))
        let durationHours = max(durationMinutes / 60, occurrence.event.isAllDay ? 8 : 0.25)
        let tokenScale = min(max(4 + durationHours * 7, 4), 22)
        let physicalScale = min(max(80 + durationHours * 180, 80), 650)
        let tomorrowTokenScale = min(max(4 + durationHours * 5, 4), 18)
        let tomorrowPhysicalScale = min(max(90 + durationHours * 160, 90), 700)

        let activeMeta = repository.activeMetaHypotheses(at: occurrence.range.end)
        let metaPenalty = activeMeta.reduce(0.0) { partial, meta in
            switch meta.kind {
            case .inputSparse:
                return partial + meta.confidence * 0.08
            case .contextMissing:
                return partial + meta.confidence * 0.12
            case .oneSidedData:
                return partial + meta.confidence * 0.08
            case .testingBehavior:
                return partial + meta.confidence * 0.18
            }
        }

        let deltaToken: Double
        let deltaPhysical: Double
        let tomorrowTokenDelta: Double
        let tomorrowPhysicalDelta: Double
        let confidence: Double

        if abstain {
            deltaToken = prior.heuristicTokenDelta * 0.18
            deltaPhysical = prior.heuristicPhysicalDelta * 0.18
            tomorrowTokenDelta = prior.heuristicTomorrowTokenDelta * 0.12
            tomorrowPhysicalDelta = prior.heuristicTomorrowPhysicalDelta * 0.12
            confidence = min(prior.confidence, 0.32)
        } else if let hint = projectionHint {
            deltaToken = hint.cognitiveToken.scalar * tokenScale
            deltaPhysical = hint.physicalCalories.scalar * physicalScale
            tomorrowTokenDelta = hint.tomorrowToken.scalar * tomorrowTokenScale
            tomorrowPhysicalDelta = hint.tomorrowPhysicalCalories.scalar * tomorrowPhysicalScale
            confidence = min(max(hint.observability.confidenceValue - metaPenalty, 0.08), 0.96)
        } else {
            deltaToken = prior.heuristicTokenDelta
            deltaPhysical = prior.heuristicPhysicalDelta
            tomorrowTokenDelta = prior.heuristicTomorrowTokenDelta
            tomorrowPhysicalDelta = prior.heuristicTomorrowPhysicalDelta
            confidence = min(max(prior.confidence - metaPenalty, 0.08), 0.94)
        }

        let discount = 0.45 + 0.55 * confidence
        let tokenAfter = min(max(prior.startingToken + deltaToken * discount, TokenCalibration.projectionFloor), TokenCalibration.projectionCeiling)
        let physicalAfter = min(max(prior.startingPhysicalCalories + deltaPhysical * discount, TokenCalibration.physicalFloor), TokenCalibration.physicalCeiling)
        let nextDayToken = min(
            max(
                tokenAfter + tomorrowTokenDelta,
                TokenCalibration.nextDayBaselineFloor
            ),
            TokenCalibration.projectionCeiling
        )
        let nextDayPhysical = min(
            max(
                physicalAfter + tomorrowPhysicalDelta,
                TokenCalibration.nextDayPhysicalBaselineFloor
            ),
            TokenCalibration.physicalCeiling
        )
        let occurrenceKey = CalendarOccurrenceKey.make(for: occurrence.event, occurrenceDate: occurrenceDay)

        let finalEvidence = mergedEvidence(primary: evidence, fallback: prior.evidence, abstain: abstain)
        let finalStateTags = normalizedTags(stateTags.isEmpty ? prior.suggestedStateTags : stateTags)

        return TokenOccurrenceProjectionRecord(
            occurrenceKey: occurrenceKey,
            occurrenceID: occurrence.id,
            eventID: occurrence.event.id,
            eventTitle: occurrence.event.title,
            typeLabel: occurrence.event.type.isEmpty ? "Other" : occurrence.event.type,
            start: occurrence.range.start,
            end: occurrence.range.end,
            phase: mode == .prediction ? .predicted : .reconciled,
            tokenBefore: prior.startingToken,
            tokenAfter: tokenAfter,
            physicalCaloriesBefore: prior.startingPhysicalCalories,
            physicalCaloriesAfter: physicalAfter,
            nextDayToken: nextDayToken,
            nextDayPhysicalCalories: nextDayPhysical,
            confidence: confidence,
            dimensions: TokenDimensionBreakdown(
                cognitiveTokenDelta: deltaToken * discount,
                physicalCaloriesDelta: deltaPhysical * discount,
                tomorrowTokenDelta: tomorrowTokenDelta,
                tomorrowCaloriesDelta: tomorrowPhysicalDelta,
                observability: confidence
            ),
            reasoningSummary: (reasoningSummary?.isEmpty == false ? reasoningSummary : nil)
                ?? (abstain
                    ? "The system abstained from a stronger interpretation because observability stayed too weak."
                    : "Projection was derived from active world-model and state hypotheses, then grounded into token and calorie outputs."),
            evidence: finalEvidence,
            stateTags: finalStateTags,
            dynamicHypothesisIDs: dynamicHypothesisIDs,
            metaHypothesisKinds: metaHypothesisKinds,
            inferenceSourceLabel: sourceLabel,
            abstained: abstain,
            updatedAt: Date()
        )
    }

    private func mergedEvidence(
        primary: TokenEvidenceBundle,
        fallback: TokenEvidenceBundle,
        abstain: Bool
    ) -> TokenEvidenceBundle {
        let abstainNote = abstain ? ["Observability stayed low, so the projection was damped."] : []
        return TokenEvidenceBundle(
            direct: Array((primary.direct.isEmpty ? fallback.direct : primary.direct).prefix(6)),
            structural: Array(((primary.structural.isEmpty ? fallback.structural : primary.structural) + abstainNote).prefix(6)),
            historical: Array((primary.historical.isEmpty ? fallback.historical : primary.historical).prefix(5))
        )
    }

    private func initialTokenBaseline(before day: Date, store: EventStore) -> Double {
        guard let previousDay = calendar.date(byAdding: .day, value: -1, to: day) else {
            return TokenCalibration.neutralDailyCapacity
        }
        let priorOccurrences = CalendarLayout.occurrencesForDate(store.calendarEvents, date: previousDay, calendar: calendar)
        guard !priorOccurrences.isEmpty else { return TokenCalibration.neutralDailyCapacity }

        var lift = 0.0
        for occurrence in priorOccurrences {
            let text = [occurrence.event.title, occurrence.event.type, occurrence.event.note]
                .joined(separator: " ")
                .lowercased()
            if containsAny(text, matches: ["sleep", "rest", "recover", "shower", "bath"]) {
                lift += 4
            }
            if containsAny(text, matches: ["work", "meeting", "deadline", "exercise", "labor", "study"]) {
                lift -= 2.4
            }
        }
        return min(max(TokenCalibration.neutralDailyCapacity + lift, 54), 118)
    }

    private func initialPhysicalBaseline(before day: Date, store: EventStore) -> Double {
        guard let previousDay = calendar.date(byAdding: .day, value: -1, to: day) else {
            return TokenCalibration.neutralPhysicalCalories
        }
        let priorOccurrences = CalendarLayout.occurrencesForDate(store.calendarEvents, date: previousDay, calendar: calendar)
        guard !priorOccurrences.isEmpty else { return TokenCalibration.neutralPhysicalCalories }

        var lift = 0.0
        for occurrence in priorOccurrences {
            let text = [occurrence.event.title, occurrence.event.type, occurrence.event.note]
                .joined(separator: " ")
                .lowercased()
            if containsAny(text, matches: ["sleep", "rest", "recover", "meal", "tv", "movie"]) {
                lift += 140
            }
            if containsAny(text, matches: ["exercise", "run", "workout", "labor", "chores", "travel"]) {
                lift -= 180
            }
        }
        return min(max(TokenCalibration.neutralPhysicalCalories + lift, 1200), TokenCalibration.physicalCeiling)
    }

    private func containsAny(_ text: String, matches keywords: [String]) -> Bool {
        keywords.contains { text.contains($0) }
    }

    private func answerString(fieldID: String, record: CalendarEventLogRecord?) -> String? {
        guard let record,
              let value = record.templateAnswers[fieldID] else { return nil }
        if case .string(let stringValue) = value {
            return stringValue
        }
        return nil
    }

    private func answerStrings(fieldID: String, record: CalendarEventLogRecord?) -> [String] {
        guard let record,
              let value = record.templateAnswers[fieldID] else { return [] }
        if case .strings(let values) = value {
            return values
        }
        return []
    }
}

enum TokenAnalysisAssembler {
    @MainActor
    static func build(
        store: EventStore,
        dateRange: (start: Date, end: Date),
        period: AnalysisPeriod,
        metadata: TokenInferenceSyncMetadata?
    ) -> TokenHypothesisAnalysis {
        let repository = TokenInferenceRepository.shared
        let records = repository.projections(in: dateRange.start..<dateRange.end)
        let dynamicSupport = Dictionary(grouping: records.flatMap(\.dynamicHypothesisIDs), by: { $0 }).mapValues(\.count)
        let metaSupport = Dictionary(grouping: records.flatMap(\.metaHypothesisKinds), by: { $0 }).mapValues(\.count)
        let combinedHypotheses = combinedSnapshots(
            repository: repository,
            dynamicSupport: dynamicSupport,
            metaSupport: metaSupport
        )

        let calendar = Calendar.current
        var current = calendar.startOfDay(for: dateRange.start)
        var dayAnalyses: [TokenDayAnalysis] = []

        while current < dateRange.end {
            let next = calendar.date(byAdding: .day, value: 1, to: current) ?? dateRange.end
            let dayRecords = records.filter { $0.start >= current && $0.start < next }
                .sorted { lhs, rhs in lhs.start < rhs.start }

            if !dayRecords.isEmpty {
                let dayHypotheses = aggregateSnapshots(dayRecords.flatMap { record in
                    recordHypotheses(record, repository: repository)
                })
                let averageConfidence = dayRecords.map(\.confidence).reduce(0, +) / Double(dayRecords.count)
                let nextDayTokenCenter = dayRecords.last?.nextDayToken ?? TokenCalibration.neutralDailyCapacity
                let nextDayPhysicalCenter = dayRecords.last?.nextDayPhysicalCalories ?? TokenCalibration.neutralPhysicalCalories
                let tokenUncertainty = max(6, (1 - averageConfidence) * 18)
                let physicalUncertainty = max(120, (1 - averageConfidence) * 420)
                let stateTags = aggregateTags(dayRecords.flatMap(\.stateTags))

                dayAnalyses.append(
                    TokenDayAnalysis(
                        id: "\(Int(current.timeIntervalSince1970))",
                        date: current,
                        startingToken: dayRecords.first?.tokenBefore ?? TokenCalibration.neutralDailyCapacity,
                        endingToken: dayRecords.last?.tokenAfter ?? TokenCalibration.neutralDailyCapacity,
                        startingPhysicalCalories: dayRecords.first?.physicalCaloriesBefore ?? TokenCalibration.neutralPhysicalCalories,
                        endingPhysicalCalories: dayRecords.last?.physicalCaloriesAfter ?? TokenCalibration.neutralPhysicalCalories,
                        averageConfidence: averageConfidence,
                        nextDayTokenRange: max(TokenCalibration.nextDayFloor, nextDayTokenCenter - tokenUncertainty)...min(TokenCalibration.projectionCeiling, nextDayTokenCenter + tokenUncertainty),
                        nextDayPhysicalCaloriesRange: max(TokenCalibration.nextDayPhysicalFloor, nextDayPhysicalCenter - physicalUncertainty)...min(TokenCalibration.physicalCeiling, nextDayPhysicalCenter + physicalUncertainty),
                        summary: daySummary(dayRecords: dayRecords),
                        flow: flowPoints(for: dayRecords, day: current),
                        eventAnalyses: dayRecords.map { record in
                            TokenEventAnalysis(
                                id: record.id,
                                eventID: record.eventID,
                                title: record.eventTitle,
                                typeLabel: record.typeLabel,
                                start: record.start,
                                end: record.end,
                                tokenBefore: record.tokenBefore,
                                tokenAfter: record.tokenAfter,
                                tokenChange: record.tokenAfter - record.tokenBefore,
                                physicalCaloriesBefore: record.physicalCaloriesBefore,
                                physicalCaloriesAfter: record.physicalCaloriesAfter,
                                physicalCaloriesChange: record.physicalCaloriesAfter - record.physicalCaloriesBefore,
                                confidence: record.confidence,
                                dimensions: record.dimensions,
                                summary: record.reasoningSummary,
                                evidence: record.evidence,
                                stateTags: record.stateTags,
                                hypotheses: recordHypotheses(record, repository: repository)
                            )
                        },
                        hypotheses: dayHypotheses,
                        stateTags: stateTags
                    )
                )
            }

            current = next
        }

        let latestProjection = dayAnalyses.last?.eventAnalyses.last
        let avgConfidence = dayAnalyses.isEmpty ? 0 : dayAnalyses.map(\.averageConfidence).reduce(0, +) / Double(dayAnalyses.count)
        let fallbackReason: String? = records.isEmpty
            ? (metadata?.fallbackReason ?? "No projections exist in this window yet.")
            : metadata?.fallbackReason

        return TokenHypothesisAnalysis(
            currentToken: latestProjection?.tokenAfter ?? TokenCalibration.neutralDailyCapacity,
            currentPhysicalCalories: latestProjection?.physicalCaloriesAfter ?? TokenCalibration.neutralPhysicalCalories,
            averageConfidence: avgConfidence,
            nextDayTokenRange: dayAnalyses.last?.nextDayTokenRange ?? TokenCalibration.emptyWindowRange,
            nextDayPhysicalCaloriesRange: dayAnalyses.last?.nextDayPhysicalCaloriesRange ?? TokenCalibration.emptyPhysicalRange,
            currentStateTags: dayAnalyses.last?.stateTags ?? [],
            dayAnalyses: dayAnalyses,
            evolvingHypotheses: combinedHypotheses,
            usedLLM: metadata?.usedLLM ?? records.contains { !$0.inferenceSourceLabel.isEmpty && $0.inferenceSourceLabel != TokenInferenceService.bootstrapSourceLabel },
            analysisSourceLabel: metadata?.sourceLabel ?? (records.last?.inferenceSourceLabel ?? "Stored Projections"),
            fallbackReason: fallbackReason
        )
    }

    @MainActor
    private static func combinedSnapshots(
        repository: TokenInferenceRepository,
        dynamicSupport: [String: Int],
        metaSupport: [TokenMetaHypothesisKind: Int]
    ) -> [TokenHypothesisSnapshot] {
        let dynamic = repository.dynamicHypotheses
            .filter { $0.status != .pruned }
            .map { record in
                TokenHypothesisSnapshot(
                    id: record.id,
                    statement: record.statement,
                    kind: record.category.uiKind,
                    confidence: record.confidence,
                    confidenceDelta: 0,
                    evidenceSummary: record.rationale,
                    supportCount: dynamicSupport[record.id] ?? record.relatedOccurrenceKeys.count,
                    isPersistent: record.category == .compressed,
                    lastUpdated: record.updatedAt
                )
            }

        let meta = repository.metaHypotheses
            .filter { $0.status != .pruned }
            .map { record in
                TokenHypothesisSnapshot(
                    id: "meta-\(record.kind.rawValue)",
                    statement: record.kind.title,
                    kind: .meta,
                    confidence: record.confidence,
                    confidenceDelta: 0,
                    evidenceSummary: record.rationale,
                    supportCount: metaSupport[record.kind] ?? 0,
                    isPersistent: false,
                    lastUpdated: record.updatedAt
                )
            }

        return aggregateSnapshots(dynamic + meta).prefix(12).map { $0 }
    }

    @MainActor
    private static func recordHypotheses(
        _ record: TokenOccurrenceProjectionRecord,
        repository: TokenInferenceRepository
    ) -> [TokenHypothesisSnapshot] {
        let dynamicLookup = Dictionary(uniqueKeysWithValues: repository.dynamicHypotheses.map { ($0.id, $0) })
        let metaLookup = Dictionary(uniqueKeysWithValues: repository.metaHypotheses.map { ($0.kind, $0) })

        var snapshots: [TokenHypothesisSnapshot] = []
        for id in record.dynamicHypothesisIDs {
            if let hypothesis = dynamicLookup[id], hypothesis.status != .pruned {
                snapshots.append(
                    TokenHypothesisSnapshot(
                        id: hypothesis.id,
                        statement: hypothesis.statement,
                        kind: hypothesis.category.uiKind,
                        confidence: hypothesis.confidence,
                        confidenceDelta: 0,
                        evidenceSummary: hypothesis.rationale,
                        supportCount: hypothesis.relatedOccurrenceKeys.count,
                        isPersistent: hypothesis.category == .compressed,
                        lastUpdated: hypothesis.updatedAt
                    )
                )
            }
        }
        for kind in record.metaHypothesisKinds {
            if let meta = metaLookup[kind], meta.status != .pruned {
                snapshots.append(
                    TokenHypothesisSnapshot(
                        id: "meta-\(meta.kind.rawValue)",
                        statement: meta.kind.title,
                        kind: .meta,
                        confidence: meta.confidence,
                        confidenceDelta: 0,
                        evidenceSummary: meta.rationale,
                        supportCount: 1,
                        isPersistent: false,
                        lastUpdated: meta.updatedAt
                    )
                )
            }
        }
        return aggregateSnapshots(snapshots)
    }

    private static func aggregateSnapshots(_ snapshots: [TokenHypothesisSnapshot]) -> [TokenHypothesisSnapshot] {
        Dictionary(grouping: snapshots, by: \.id)
            .compactMap { _, group in
                guard let first = group.first else { return nil }
                let confidence = group.map(\.confidence).reduce(0, +) / Double(group.count)
                let latest = group.max(by: { $0.lastUpdated < $1.lastUpdated }) ?? first
                return TokenHypothesisSnapshot(
                    id: first.id,
                    statement: latest.statement,
                    kind: latest.kind,
                    confidence: confidence,
                    confidenceDelta: 0,
                    evidenceSummary: latest.evidenceSummary,
                    supportCount: group.map(\.supportCount).reduce(0, +),
                    isPersistent: group.contains(where: \.isPersistent),
                    lastUpdated: latest.lastUpdated
                )
            }
            .sorted { lhs, rhs in
                if lhs.confidence != rhs.confidence { return lhs.confidence > rhs.confidence }
                return lhs.lastUpdated > rhs.lastUpdated
            }
    }

    private static func aggregateTags(_ tags: [String]) -> [String] {
        Dictionary(grouping: normalizedTags(tags), by: { $0 })
            .sorted { lhs, rhs in
                if lhs.value.count != rhs.value.count { return lhs.value.count > rhs.value.count }
                return lhs.key < rhs.key
            }
            .prefix(3)
            .map(\.key)
    }

    private static func daySummary(dayRecords: [TokenOccurrenceProjectionRecord]) -> String {
        if dayRecords.contains(where: \.abstained) {
            return "Some occurrences stayed weakly observable, so the projection remained conservative."
        }
        let tokenDelta = (dayRecords.last?.tokenAfter ?? 0) - (dayRecords.first?.tokenBefore ?? 0)
        let physicalDelta = (dayRecords.last?.physicalCaloriesAfter ?? 0) - (dayRecords.first?.physicalCaloriesBefore ?? 0)
        if tokenDelta > 8 && physicalDelta < -200 {
            return "Cognition recovered while physical reserve was spent."
        }
        if tokenDelta < -8 && physicalDelta < -200 {
            return "Both cognition and physical reserve were pulled down."
        }
        if tokenDelta > 8 && physicalDelta > 120 {
            return "Both cognition and physical reserve trended upward."
        }
        return "The day stayed mixed and hypothesis-driven."
    }

    private static func flowPoints(for records: [TokenOccurrenceProjectionRecord], day: Date) -> [TokenFlowPoint] {
        var points: [TokenFlowPoint] = [
            TokenFlowPoint(
                id: "\(Int(day.timeIntervalSince1970))-start",
                stepIndex: 0,
                label: "Start",
                date: day,
                token: records.first?.tokenBefore ?? TokenCalibration.neutralDailyCapacity,
                physicalCalories: records.first?.physicalCaloriesBefore ?? TokenCalibration.neutralPhysicalCalories,
                confidence: 1
            )
        ]

        for (index, record) in records.enumerated() {
            points.append(
                TokenFlowPoint(
                    id: record.id,
                    stepIndex: index + 1,
                    label: shortTimeLabel(record.end),
                    date: record.end,
                    token: record.tokenAfter,
                    physicalCalories: record.physicalCaloriesAfter,
                    confidence: record.confidence
                )
            )
        }
        return points
    }

    private static func shortTimeLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

private extension UserDefaults {
    func codableValue<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    func setCodable<T: Encodable>(_ value: T, forKey key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        set(data, forKey: key)
    }
}

private let dayOnlyFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    return formatter
}()

private func isoDateString(_ date: Date) -> String {
    dayOnlyFormatter.string(from: date)
}

private func parseISODate(_ value: String?) -> Date? {
    guard let value, !value.isEmpty else { return nil }
    if let day = dayOnlyFormatter.date(from: value) {
        return day
    }
    let formatter = ISO8601DateFormatter()
    return formatter.date(from: value)
}

private func normalizedCue(_ text: String) -> String {
    text
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
        .replacingOccurrences(of: " ", with: "-")
}

private func normalizedTags(_ tags: [String]) -> [String] {
    Array(
        LinkedHashSet(
            tags
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    )
}

private func semanticCompressionKey(_ text: String) -> String {
    topMeaningfulTokens(from: text, limit: 3).joined(separator: "-")
}

private func topMeaningfulTokens(from text: String, limit: Int) -> [String] {
    let stopWords: Set<String> = [
        "the", "and", "for", "with", "from", "that", "this", "into", "about",
        "current", "likely", "user", "their", "they", "them", "event", "mode",
        "state", "world", "model", "hypothesis", "around", "merged"
    ]
    let pieces = text
        .lowercased()
        .components(separatedBy: CharacterSet.alphanumerics.inverted)
        .filter { $0.count > 2 && !stopWords.contains($0) }
    return Array(LinkedHashSet(pieces).prefix(limit))
}

private func jsonResult(success: Bool, message: String) -> String {
    let payload = TokenToolResultEnvelope(success: success, message: message)
    return jsonEncoded(payload) ?? "{\"success\":false,\"message\":\"encoding failed\"}"
}

private func jsonEncoded<T: Encodable>(_ value: T) -> String? {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    guard let data = try? encoder.encode(value) else { return nil }
    return String(data: data, encoding: .utf8)
}

private struct TokenToolResultEnvelope: Encodable {
    var success: Bool
    var message: String
}

private struct LinkedHashSet<Element: Hashable>: Sequence, ExpressibleByArrayLiteral {
    private var set: Set<Element> = []
    private var ordered: [Element] = []

    init() {}

    init(arrayLiteral elements: Element...) {
        for element in elements {
            append(element)
        }
    }

    init(_ elements: [Element]) {
        for element in elements {
            append(element)
        }
    }

    mutating func append(_ element: Element) {
        if set.insert(element).inserted {
            ordered.append(element)
        }
    }

    func makeIterator() -> IndexingIterator<[Element]> {
        ordered.makeIterator()
    }

    func prefix(_ maxLength: Int) -> ArraySlice<Element> {
        ordered.prefix(maxLength)
    }
}
