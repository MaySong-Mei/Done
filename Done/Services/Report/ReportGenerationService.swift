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
    // (EVENTS budget raised alongside — records add real weight to the input.)
    /// Apple's on-device model shares a single 4096-token window across prompt AND
    /// output, so the data block has to leave room for the prose inside the same
    /// budget — a much tighter cap than the cloud path.
    private let promptBudgetOnDevice = 1200

    /// Budget for the EVENTS block — the raw records (titles, notes) that let
    /// the report reference specific moments.  Cloud only: the on-device 4096
    /// shared window can't fit event detail, so the AFM tier stays stats-only
    /// (this is the B→C detail knob from #111, closed on-device, open on cloud).
    private let eventsBudgetCloud = 5000

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
        logRecords: [CalendarEventLogRecord] = [],
        feedbackRecords: [CalendarEventFeedbackRecord] = [],
        createdAt: Date = Date()
    ) async throws -> Report {
        let built = try buildProvider()

        let stats = ReportStatsBuilder.build(events: events, start: start, end: end, calendar: calendar)
        let isPartial = createdAt < end
        let compare = Self.includeComparisons(stats: stats, isPartial: isPartial)
        let budget = built.isOnDevice ? promptBudgetOnDevice : promptBudgetCloud
        let dataBlock = stats.promptText(budget: budget, includeChanges: compare)

        // Vision path: when the cloud provider can see images, preload every
        // window-log photo from disk (this runs off the main actor, so blocking
        // reads are fine) and let the serializer decide which to attach and how
        // to mark them.  The set is a superset of what gets attached — the
        // serializer only numbers photos it emits inside the budgeted block, so
        // handing it every readable ref is harmless.
        let canAttachPhotos = !built.isOnDevice && built.provider.supportsVision
        // Only records whose occurrence can fall inside the window matter for
        // attachment — without this scope the preload reads the user's entire
        // photo history off disk on every generation, growing with lifetime
        // usage.  The ±2-day margin absorbs cross-midnight sessions and the
        // single-event key anchoring on the primary range start; a record
        // outside it simply keeps its indexless [photo] marker.
        let preloadMargin: TimeInterval = 2 * 86_400
        let preloadedImages: [UUID: Data] = canAttachPhotos
            ? Self.preloadImages(logRecords: logRecords.filter {
                $0.occurrenceDate >= start.addingTimeInterval(-preloadMargin)
                    && $0.occurrenceDate < end.addingTimeInterval(preloadMargin)
            })
            : [:]

        let eventsBlock = ReportStatsBuilder.promptEvents(
            events: events,
            start: start,
            end: end,
            calendar: calendar,
            budget: built.isOnDevice ? 0 : eventsBudgetCloud,
            logRecords: logRecords,
            feedbackRecords: feedbackRecords,
            attachableImageIDs: Set(preloadedImages.keys)
        )

        // Assemble the attachments in the exact order the serializer numbered
        // them, so `attachedImageRefs[k - 1]` is the `[photo #k]` image.
        let images: [LLMVisionImage] = eventsBlock.attachedImageRefs.compactMap { ref in
            preloadedImages[ref.id].map { LLMVisionImage(data: $0, mimeType: "image/jpeg") }
        }

        let userPromptText = userPrompt(dataBlock: dataBlock, eventsBlock: eventsBlock.text)
        let sysPrompt = systemPrompt(
            language: language,
            isThin: stats.window.isThin,
            isOnDevice: built.isOnDevice,
            isPartial: isPartial,
            emptyBaseline: !isPartial && !compare,
            hasAttachedPhotos: !images.isEmpty,
            hasEvents: !eventsBlock.text.isEmpty
        )

        let response: LLMResponse
        do {
            if images.isEmpty {
                response = try await built.provider.send(LLMRequest(
                    messages: [LLMMessage(role: .user, content: userPromptText, toolCalls: nil, toolCallId: nil)],
                    tools: [],
                    systemPrompt: sysPrompt
                ))
            } else {
                do {
                    response = try await built.provider.sendVision(LLMVisionRequest(
                        messages: [LLMVisionMessage(role: .user, text: userPromptText, images: images)],
                        systemPrompt: sysPrompt
                    ))
                } catch let error where Self.endpointRejectedVision(error) {
                    // `supportsVision` is a client-side claim; the actual
                    // endpoint (a relay, a restricted key, an older model) can
                    // still reject image input.  Retrying the same request
                    // would hit the same wall forever, so degrade once to the
                    // text-only path — re-serialized so no dangling
                    // `[photo #k]` marker survives.  Transient failures
                    // (network, 5xx) don't take this branch and stay
                    // retryable with photos.
                    let textOnly = ReportStatsBuilder.promptEvents(
                        events: events,
                        start: start,
                        end: end,
                        calendar: calendar,
                        budget: eventsBudgetCloud,
                        logRecords: logRecords,
                        feedbackRecords: feedbackRecords
                    )
                    response = try await built.provider.send(LLMRequest(
                        messages: [LLMMessage(
                            role: .user,
                            content: userPrompt(dataBlock: dataBlock, eventsBlock: textOnly.text),
                            toolCalls: nil,
                            toolCallId: nil
                        )],
                        tools: [],
                        systemPrompt: systemPrompt(
                            language: language,
                            isThin: stats.window.isThin,
                            isOnDevice: built.isOnDevice,
                            isPartial: isPartial,
                            emptyBaseline: !isPartial && !compare,
                            hasAttachedPhotos: false,
                            hasEvents: !textOnly.text.isEmpty
                        )
                    ))
                }
            }
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
            comparedToPreviousWindow: compare,
            schemaVersion: Report.currentSchemaVersion
        )
        try store.save(report)
        return report
    }

    /// Comparison material (CATEGORY prev/delta, CHANGE lines) only goes to
    /// the model when the window is complete AND the previous window actually
    /// has records.  Comparing an in-progress window is misleading by
    /// construction; comparing against an untracked previous window would
    /// narrate every category as a fabricated increase — the data can't tell
    /// 0-tracked from 0-happened.  (`previousHours` covers every type seen in
    /// either window, so "all zero" ⟺ "no previous records".)
    static func includeComparisons(stats: ReportStats, isPartial: Bool) -> Bool {
        !isPartial && stats.perTypeHours.contains { $0.previousHours > 0 }
    }

    // Reads every note photo referenced by the window's log records off disk,
    // keyed by image-ref id (deduped: the same ref never loads twice).  Only
    // successfully read images make it into the map — an unreadable ref is
    // silently skipped, so it also never becomes attachable.  Called off the
    // main actor from `generate`, where blocking file reads are acceptable.
    private static func preloadImages(logRecords: [CalendarEventLogRecord]) -> [UUID: Data] {
        let assetStore = AgenticIntakeAssetStore()
        var result: [UUID: Data] = [:]
        for record in logRecords {
            for item in record.timelineItems {
                guard case .note(let note) = item else { continue }
                for ref in note.images where result[ref.id] == nil {
                    if let data = try? Data(contentsOf: assetStore.absoluteURL(for: ref)) {
                        result[ref.id] = data
                    }
                }
            }
        }
        return result
    }

    /// True when a vision request failed because the endpoint refused the
    /// request itself — the provider's own `visionUnsupported`, or a 4xx API
    /// rejection (the server understood the request and said no; images are
    /// the only thing distinguishing it from the always-accepted text path).
    /// Auth (401/403), timeout (408), and rate-limit (429) are excluded: a
    /// text retry would fail identically or the condition is transient, so
    /// those keep the normal retry path with photos intact — as do 5xx and
    /// transport errors.
    private static func endpointRejectedVision(_ error: Error) -> Bool {
        switch error {
        case LLMError.visionUnsupported:
            return true
        case LLMError.apiError(let statusCode, _):
            return (400...499).contains(statusCode)
                && ![401, 403, 408, 429].contains(statusCode)
        default:
            return false
        }
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

    // Prompt v2 (dogfood-driven rewrite): one positive persona instead of a
    // prohibition list.  Earlier versions stacked ~15 rules (no-imply, voice,
    // select, exact quoting, never-print lists…) and the accumulated effect
    // was a model writing with both hands tied — safe but dead, "太 technical".
    // What survives is only what has evidence behind it: no generic praise
    // (the retention sims' one hard-validated result), no invented records or
    // numbers, and no judging (design bedrock).  Everything else trusts the
    // model to do what it is good at: telling a person's stretch of time back
    // to them naturally.
    private func systemPrompt(language: AppLanguage, isThin: Bool, isOnDevice: Bool, isPartial: Bool, emptyBaseline: Bool, hasAttachedPhotos: Bool, hasEvents: Bool) -> String {
        let outputLanguage: String
        switch language {
        case .english: outputLanguage = "English"
        case .chinese: outputLanguage = "Simplified Chinese"
        }

        // The on-device model shares its 4096-token window between prompt and
        // output, so ask for a shorter report to stay inside it.
        let lengthGuidance = isOnDevice ? "150–300 words" : "200–400 words"

        // Promising an EVENTS list the message doesn't contain (the on-device
        // tier, or an empty window) nudges the weakest models toward inventing
        // one — the material paragraph only describes what is actually there.
        let materialIntro = hasEvents
            ? """
            You get an EVENTS list (their real records: day, time, category, title, notes in their own words) and a DATA summary (pre-computed totals, changes, and patterns you can trust; [high]/[medium] tags mark how solid a pattern is). Some EVENT lines have indented LOG/FELT/NOTE sub-lines underneath — that is what this person wrote down at the time about how it went (effort, mood, what happened, a note to themselves); it is the most precious material you have, so reach for their own words when you use it. A `[photo]` marker means they attached a picture then. Lead with what actually happened — the concrete things, in their own words where that helps.
            """
            : """
            You get a DATA summary (pre-computed totals, changes, and patterns you can trust; [high]/[medium] tags mark how solid a pattern is) — no individual records this time, so work from the shape of the numbers and don't invent specifics.
            """

        var prompt = """
        You are writing a short recap of one person's stretch of time, based on their own time-tracking records. Write like a perceptive friend who looked through their calendar and is telling them what you see — natural, specific, human. Not a data analysis, not a productivity assessment: a normal account of what their days actually looked like.

        \(materialIntro) Use numbers only where they carry the story, rounded and casual ("about four hours"). You may notice patterns and gently say what they look like; lean only on solid ones, and hold shaky ones loosely or not at all.

        Boundaries (each is here for a reason):
        - Don't judge, lecture, or prescribe. You're recounting their life, not grading it.
        - No generic praise or cheerleading — "great job, keep it up" reads hollow. Specific noticing is worth more than any compliment.
        - Don't invent events, details, or numbers that aren't in the records. Everything you say should be traceable to what you were given.
        - If there is little data, write a few honest sentences and stop — never pad.

        FORMAT: flowing prose, Markdown allowed but no top-level H1 heading, \(lengthGuidance). Write entirely in \(outputLanguage).
        """

        if isPartial {
            prompt += "\n\nThe period is still in progress — frame it as \"so far\", and don't compare against any previous period."
        }

        if emptyBaseline {
            prompt += "\n\nThe previous period has no records, so comparison material was omitted — describe this stretch on its own, without claims about how it compares to before."
        }

        if isThin {
            prompt += "\n\nThis window has very little data — a few honest sentences is the right length."
        }

        if hasAttachedPhotos {
            prompt += "\n\nSome of their notes have photos they took at the moment, and those pictures are attached to this message. In the EVENTS list a `[photo #k]` marker points to the k-th attached image, so you can tell which moment each picture belongs to — actually look at them and let what you see settle naturally into the telling, the way you'd take in a friend's photo. A photo marked without a number (plain `[photo]`) isn't attached here, so don't describe what's in it."
        }

        return prompt
    }

    private func userPrompt(dataBlock: String, eventsBlock: String) -> String {
        // EVENTS leads — the recap is about what happened; the numeric
        // summary is the frame.  The header only mentions the records when
        // the block is actually present (a dangling reference would nudge the
        // weakest models toward inventing specifics).
        var sections = [
            eventsBlock.isEmpty
                ? "Write the recap from the DATA summary below."
                : "Write the recap from the records and the summary below.",
        ]
        if !eventsBlock.isEmpty {
            sections.append("EVENTS\n\(eventsBlock)")
        }
        sections.append("DATA\n\(dataBlock)")
        return sections.joined(separator: "\n\n")
    }
}
