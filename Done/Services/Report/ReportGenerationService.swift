//
//  ReportGenerationService.swift
//  Done
//
//  Turns a window of events into a persisted, generated report (Discussion
//  #111).  The pipeline is: build the numeric stats off the calculation path
//  (`ReportStatsBuilder`), serialize them into a token-budgeted data block
//  (`ReportStats.promptText`), hand that block plus a strict system prompt to
//  the user's configured BYOK model, wrap the returned prose in a `Report`, and
//  persist it via `ReportStore`.
//
//  Every number the model quotes is computed here; the model only chooses
//  wording and must echo the figures verbatim (see the system prompt).
//
//  Error policy is the deliberate opposite of `AnalysisSuggestionService`, which
//  swallows every failure into an empty result: here nothing is swallowed.  A
//  missing key, a network/API failure, and an empty response are three distinct
//  thrown cases so the UI can tell "you haven't set up a key" apart from "the
//  call failed".
//

import Foundation

/// Distinct, user-distinguishable report failures.  `errorDescription` is
/// localized because these surface directly in the UI.
enum ReportGenerationError: Error, LocalizedError {
    /// No BYOK key configured — the user must set one up, not retry.
    case noAPIKey
    /// The provider call itself failed (network, HTTP error, decode); carries
    /// the underlying error for logging.
    case generationFailed(underlying: Error)
    /// The call succeeded but returned no usable prose.
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            return L(.reportErrorNoAPIKey)
        case .generationFailed:
            return L(.reportErrorGenerationFailed)
        case .emptyResponse:
            return L(.reportErrorEmptyResponse)
        }
    }
}

/// Not `@MainActor`: `generate` is a non-isolated async method, so the CPU-bound
/// `ReportStatsBuilder.build` runs off the main actor even when the caller is on
/// it.
final class ReportGenerationService {

    private let store: ReportStore

    /// Coarse token budget for the serialized data block.  `promptText` keeps the
    /// most licensed material (window, category hours, high-confidence
    /// relationships) and truncates the rest to fit; ~2500 tokens leaves ample
    /// room under the cloud providers' hard-coded 4096 `max_tokens` for the prose.
    private let promptBudgetCloud = 2500
    /// Apple's on-device model shares a single 4096-token window across prompt AND
    /// output, so the data block has to leave room for the prose inside the same
    /// budget — a much tighter cap than the cloud path.
    private let promptBudgetOnDevice = 1200

    init(store: ReportStore = ReportStore()) {
        self.store = store
    }

    /// Builds stats, generates prose, persists, and returns the report.
    ///
    /// - Parameter createdAt: the generation moment stamped onto the report;
    ///   injected so the calculation path stays wall-clock-free and tests can
    ///   pin it.
    /// - Throws: `ReportGenerationError` — `.noAPIKey`, `.generationFailed`, or
    ///   `.emptyResponse`.
    func generate(
        events: [Event],
        start: Date,
        end: Date,
        calendar: Calendar,
        language: AppLanguage,
        createdAt: Date = Date()
    ) async throws -> Report {
        let built = try buildProvider()

        let stats = ReportStatsBuilder.build(events: events, start: start, end: end, calendar: calendar)
        // Generating before the window closes would compare a partial total
        // against a full previous window — misleading by construction — so the
        // comparison material is dropped from the data block entirely.
        let isPartial = createdAt < end
        let budget = built.isOnDevice ? promptBudgetOnDevice : promptBudgetCloud
        let dataBlock = stats.promptText(budget: budget, includeChanges: !isPartial)

        let request = LLMRequest(
            messages: [LLMMessage(
                role: .user,
                content: userPrompt(dataBlock: dataBlock),
                toolCalls: nil,
                toolCallId: nil
            )],
            tools: [],
            systemPrompt: systemPrompt(
                language: language,
                isThin: stats.window.isThin,
                isOnDevice: built.isOnDevice,
                isPartial: isPartial
            )
        )

        let response: LLMResponse
        do {
            response = try await built.provider.send(request)
        } catch {
            throw ReportGenerationError.generationFailed(underlying: error)
        }

        guard let prose = response.content?.trimmingCharacters(in: .whitespacesAndNewlines),
              !prose.isEmpty else {
            throw ReportGenerationError.emptyResponse
        }

        let report = Report(
            id: UUID(),
            createdAt: createdAt,
            periodStart: start,
            periodEnd: end,
            prose: prose,
            statsSnapshot: stats,
            providerModel: built.model,
            schemaVersion: Report.currentSchemaVersion
        )
        try store.save(report)
        return report
    }

    // MARK: - Provider

    // Mirrors `AnalysisSuggestionService.buildProvider` (same BYOK settings), but
    // throws `ReportGenerationError.noAPIKey` instead of returning empty, and
    // also surfaces the concrete model string for the report's provenance field.
    private func buildProvider() throws -> (provider: any LLMProvider, model: String, isOnDevice: Bool) {
        let providerType = UserDefaults.standard.string(forKey: AppSettingsKeys.agentProvider) ?? AppSettingsKeys.agentProviderDefault

        // The on-device path has no key, so it must skip the key guard entirely;
        // availability is checked lazily inside `AFMProvider.send`.
        if providerType == "apple" {
            let provider = AFMProvider()
            return (provider, provider.model, true)
        }

        let apiKey = UserDefaults.standard.string(forKey: AppSettingsKeys.agentAPIKey) ?? ""

        guard !apiKey.isEmpty else {
            throw ReportGenerationError.noAPIKey
        }

        switch providerType {
        case "openai":
            let provider = OpenAIProvider(apiKey: apiKey)
            return (provider, provider.model, false)
        case "deepseek":
            let provider = DeepSeekProvider(apiKey: apiKey)
            return (provider, provider.model, false)
        default:
            let provider = ClaudeProvider(apiKey: apiKey)
            return (provider, provider.model, false)
        }
    }

    // MARK: - Prompt

    // The report's contract with the model, in the model's working language
    // (English) but instructing output in the app language.  Encodes the #111
    // definition: horizontal relationships across the user's own categories,
    // vertical only where confident, and the three no-imply hard rules.
    private func systemPrompt(language: AppLanguage, isThin: Bool, isOnDevice: Bool, isPartial: Bool) -> String {
        let outputLanguage: String
        switch language {
        case .english: outputLanguage = "English"
        case .chinese: outputLanguage = "Simplified Chinese"
        }

        // The on-device model shares its 4096-token window between prompt and
        // output, so ask for a shorter report to stay inside it.
        let lengthGuidance = isOnDevice ? "roughly 150–300 words" : "roughly 300–500 words"

        var prompt = """
        You write a data-analysis report over one person's own time-tracking data. The report is a NO-IMPLY analysis of relationships in the numbers — nothing more.

        WHAT THE DATA MEANS
        You are given a DATA block with these line types (labels are stable, values are already computed):
        - WINDOW: the reporting period, day count, recorded days, event count, and `sparse=true` when data is thin.
        - CATEGORY: one of the user's own category words, its hours this window, its hours in the previous equal-length window, and the change.
        - CHANGE: a category's week-over-week movement that cleared the confidence bar, tagged [high] or [medium].
        - RELATION: a correlation between two categories' daily hours, with overlap-day count, tagged [high] or [medium].
        - WHEN: how a category's time distributes across morning/afternoon/evening/night.

        CONFIDENCE TAGS decide how hard you may speak:
        - [high]: enough data and a strong, consistent effect — you may state the relationship directly and may add at most one light, factual nudge ("worth a glance").
        - [medium]: state the bare relationship only — no nudge, no emphasis.
        - Anything without a tag is context; a relationship you were NOT given is one you may not claim.

        HARD RULES (never break):
        1. Do not infer motive or emotion. Never write things like "you're avoiding X", "stress is pushing you", or any why.
        2. Do not give advice or prescriptions.
        3. Do not praise or console. No cheerleading, no reassurance.
        Stop at the relationship that is in the data and let the reader interpret it.

        VOICE: plain, everyday language — you are describing someone's stretch of time back to them, not writing an analysis paper. Never use statistical or internal vocabulary: no "correlation", "r", "confidence", "effect size", "overlap days", "delta", "window", "distribution", and never echo the [high]/[medium] tags or the DATA line labels (WINDOW/CATEGORY/CHANGE/RELATION/WHEN). Express a relationship as a simple observation ("on days with more exercise, sleep ran longer"); express a change the way a person would say it ("about 4 hours less than the week before").

        SELECT, don't inventory: pick the 2–4 most notable things in the data and write about those. Never walk category-by-category through everything you were given — skip what is unremarkable instead of narrating it. If no RELATION material was given, say nothing about relationships at all; never report an absence. Never print raw dates or the window's date range — the app already shows the period around the report.

        NUMBERS: quote hour and percentage figures exactly as given in the DATA block — never compute, estimate, sum, or convert them. Correlation r values are internal evidence only: never print r itself; state the direction of the relationship in words — plainly for [high] material, neutrally hedged for [medium].

        HORIZONTAL then VERTICAL: first lay out the cross-category picture (shares of time, this window vs last, category×category relations). Only then, and only for [high] material, point downward at a single notable tension. If nothing is [high], stay horizontal.

        FORMAT: concise Markdown with a few short sections and NO top-level H1 heading. Aim for \(lengthGuidance). Write entirely in \(outputLanguage).
        """

        if isThin {
            prompt += "\n\nTHIS WINDOW IS SPARSE: there is little data. Keep the whole report to 3–5 sentences, skip sections, and soften every claim. Do not pad or invent structure to reach a length. With only a day or two of records, describe concrete parts of the day in plain words (morning, evening) — never percentages."
        }

        if isPartial {
            prompt += "\n\nTHIS WINDOW IS STILL IN PROGRESS: the report is being generated before the period has ended, so totals are partial. Describe what has happened so far, and never compare against any previous period."
        }

        return prompt
    }

    private func userPrompt(dataBlock: String) -> String {
        """
        Write the report from this DATA block. Use only these numbers, quoted exactly.

        DATA
        \(dataBlock)
        """
    }
}
