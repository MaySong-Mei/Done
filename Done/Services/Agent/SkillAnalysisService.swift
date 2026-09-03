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

/// "Has this activity already happened?" gate for skill analysis.
/// Render-frame end, not the raw stored instant (gh#208): the canvas draws
/// a traveled detached instance at its projected slot, so an instance whose
/// drawn block is still upcoming must not be analyzed just because its
/// mint-frame end already passed (and one the user watched finish must not
/// be deferred because its mint-frame end is still ahead). Identity for
/// anything that never traveled. Top-level, like
/// `skillAnalysisShouldSkipForAgenticProcessing`, so tests can pin it.
func skillAnalysisEventHasEnded(
    _ event: Event,
    now: Date = Date(),
    calendar: Calendar = .current
) -> Bool {
    guard let endTime = event.renderPrimaryTimeRange(calendar: calendar)?.end else {
        return false
    }
    return endTime <= now
}

@MainActor
final class SkillAnalysisService {
    /// Cost control: hard ceiling on paid provider calls per backlog sweep
    /// (`analyzePastEvents`). ContentView launches at most one sweep per app
    /// launch (its task handle is nil-checked, and `isBatchRunning` backstops
    /// re-entry), so this is also the per-launch ceiling for the sweep. A
    /// backlog larger than the cap drains across future launches.
    static let perLaunchAnalysisCap = 10

    private let insightStore: SkillInsightStore

    /// Test seam: overrides `buildProvider()` when non-nil. Production call
    /// sites pass nothing and get the UserDefaults-configured provider.
    private let providerFactory: (() throws -> any LLMProvider)?

    /// Re-entry guard for the backlog sweep. Set before the first suspension
    /// in `analyzePastEvents`; because the whole service is MainActor-bound,
    /// a second call observes it synchronously and returns immediately.
    private var isBatchRunning = false

    /// Event ids with a provider call currently in flight. `markAnalyzed` now
    /// runs only after a successful send, so this set is what prevents a
    /// duplicate paid call when `analyzeEvent` (record-completed callback)
    /// fires for an event the sweep is awaiting a response for.
    private var inFlightEventIds: Set<UUID> = []

    init(insightStore: SkillInsightStore, providerFactory: (() throws -> any LLMProvider)? = nil) {
        self.insightStore = insightStore
        self.providerFactory = providerFactory
    }

    func analyzeEvent(_ event: Event) async {
        await analyze(event, persistMarkImmediately: true)
    }

    func analyzePastEvents(_ events: [Event]) async {
        guard !isBatchRunning else { return }
        isBatchRunning = true
        defer {
            // One UserDefaults write per sweep — not per event — on every
            // exit path (completion, cap, cancellation). No-op if nothing
            // was marked.
            insightStore.flushAnalyzedIds()
            isBatchRunning = false
        }

        var providerCallsAttempted = 0
        for event in events {
            if Task.isCancelled { break }
            guard providerCallsAttempted < Self.perLaunchAnalysisCap else { break }
            if await analyze(event, persistMarkImmediately: false) {
                providerCallsAttempted += 1
            }
        }
    }

    // MARK: - Private

    /// Returns true iff a provider send was attempted (success or failure) —
    /// the unit the per-launch cap counts, since attempts are what cost money.
    ///
    /// When `persistMarkImmediately` is false the analyzed-id mark is kept in
    /// memory; the sweep flushes the whole set once per batch. Per-event
    /// persistence rewrites the full id set every time and each write fires
    /// `UserDefaults.didChangeNotification`, re-arming the debounced sync
    /// sinks (SupabaseSyncService / ImageBackupCoordinator) for the entire
    /// sweep.
    @discardableResult
    private func analyze(_ event: Event, persistMarkImmediately: Bool) async -> Bool {
        if skillAnalysisShouldSkipForAgenticProcessing(event) {
            return false
        }

        // Skip if already analyzed, or a send for this event is in flight.
        guard !insightStore.isAnalyzed(event.id) else { return false }
        guard !inFlightEventIds.contains(event.id) else { return false }

        // Skip short activities
        let durationMinutes = event.duration / 60
        guard durationMinutes >= 15 else { return false }

        // Skip future events — only analyze if the DRAWN end time ≤ now
        guard skillAnalysisEventHasEnded(event) else { return false }

        let provider: any LLMProvider
        do {
            provider = try makeProvider()
        } catch {
            // Provider unavailable (e.g. missing API key) — do NOT mark analyzed,
            // so the event is retried once a provider becomes available.
            return false
        }

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
            systemPrompt: "You are a skill analysis assistant. Respond with valid JSON only.",
            purpose: "skill"
        )

        inFlightEventIds.insert(event.id)
        defer { inFlightEventIds.remove(event.id) }

        do {
            let response = try await provider.send(request)
            // The send succeeded — only now is the event marked analyzed. A
            // thrown send (network / HTTP failure) leaves the id unmarked so
            // a later launch's sweep retries it; the old order marked first
            // and permanently lost the event on any transient failure.
            if persistMarkImmediately {
                insightStore.markAnalyzed(event.id)
            } else {
                insightStore.markAnalyzedDeferringSave(event.id)
            }
            if let text = response.content {
                try parseAndStore(text, event: event)
            }
        } catch {
            // Two distinct paths land here, with different marking truths
            // (QA caught the old single-sentence comment lying about the
            // second): a thrown SEND left the id unmarked above, so the
            // event IS eligible again on a later sweep; a thrown
            // parseAndStore arrives with the id ALREADY marked — deliberate:
            // the tokens were paid, and unbounded re-pay for an output that
            // may never parse is worse than capping the loss at one payment.
        }
        return true
    }

    private func makeProvider() throws -> any LLMProvider {
        if let providerFactory {
            return try providerFactory()
        }
        return try Self.buildProvider()
    }

    private static func buildProvider() throws -> any LLMProvider {
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

    // Internal (not private) so the projection test can bind to the real
    // insight-minting path rather than a copy of its date reduction.
    func parseAndStore(_ text: String, event: Event) throws {
        // Extract JSON array from response (handle markdown code blocks)
        var jsonString = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = jsonString.range(of: "["),
           let end = jsonString.range(of: "]", options: .backwards),
           start.lowerBound <= end.lowerBound {
            jsonString = String(jsonString[start.lowerBound...end.lowerBound])
        }

        guard let data = jsonString.data(using: .utf8) else { return }
        guard let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }

        // Render-frame bucket (gh#208): `SkillInsight.date` feeds the
        // per-day skill aggregates, which must land on the day the canvas
        // drew the activity, not the mint-frame day a traveled instance's
        // raw start re-buckets to.
        let eventDate = event.renderPrimaryTimeRange(calendar: .current)?.start ?? Date()

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
