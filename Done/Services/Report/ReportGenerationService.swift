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
    /// relationships) and truncates the rest to fit.  Raised 2500→3750 alongside
    /// the `charsPerToken` 3→2 tightening so the block's *character* ceiling is
    /// unchanged (2500×3 == 3750×2 == 7500 chars); the token figure now tracks
    /// the real CJK cost, still leaving ample room under the providers' 4096.
    private let promptBudgetCloud = 3750
    // (EVENTS budget raised alongside — records add real weight to the input.)
    /// Apple's on-device model shares a single 4096-token window across prompt AND
    /// output, so the data block has to leave room for the prose inside the same
    /// budget — a much tighter cap than the cloud path.  1200→1800 keeps the same
    /// 3600-char ceiling under `charsPerToken` 2.
    private let promptBudgetOnDevice = 1800

    /// Budget for the EVENTS block — the raw records (titles, notes) that let
    /// the report reference specific moments.  Cloud only: the on-device 4096
    /// shared window can't fit event detail, so the AFM tier stays stats-only
    /// (this is the B→C detail knob from #111, closed on-device, open on cloud).
    /// 5000→7500 preserves the 15000-char ceiling under `charsPerToken` 2.
    private let eventsBudgetCloud = 7500

    /// Budget for the MEMORY block — the same-kind prior reports (notes + frozen
    /// spine + prose) appended after this window's DATA/EVENTS.  Cloud only; the
    /// AFM tier gets 0 (no memory), the same degradation the EVENTS block takes
    /// on-device: the shared 4096 window has no room for it.
    private let memoryBudgetCloud = 3000

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

        // Memory: same-kind prior reports (newest 2) that closed strictly before
        // this window opens, assembled into the block appended after DATA/EVENTS.
        // Loaded off the main actor here alongside the photo preload — a disk
        // read on the calculation path, same as `preloadImages`.  The AFM tier
        // gets budget 0 → no memory, mirroring the events block's on-device
        // degradation (the shared 4096 window has no room for it).
        let priorReports = Self.selectPriorReports(
            from: store.loadAll(), start: start, end: end, calendar: calendar
        )
        let memoryBudget = built.isOnDevice ? 0 : memoryBudgetCloud

        // Backfill awareness (edit-awareness): when this run's window is complete
        // and the SPINE (newest prior report) was written over a thin window that
        // has since been filled in, the hint tells the model that stretch reads
        // fuller now — a warmth cue about their time, never a report of record
        // changes (see `shouldMentionBackfill` + the memory-block hint line).  The
        // cloud-only gate is `memoryBudget > 0`: the hint rides inside the memory
        // block, which the AFM tier (budget 0) has none of, so it degrades for
        // free alongside the rest of memory.
        let priorWindowFuller: Bool = {
            guard memoryBudget > 0, let spine = priorReports.first else { return false }
            let backfill = ReportStatsBuilder.backfilledSince(
                events: events,
                start: spine.periodStart,
                end: spine.periodEnd,
                after: spine.createdAt,
                calendar: calendar
            )
            return Self.shouldMentionBackfill(spine: spine, isPartial: isPartial, backfill: backfill)
        }()

        let memoryBlock = Self.memoryBlock(
            priorReports: priorReports,
            budget: memoryBudget,
            calendar: calendar,
            priorWindowFuller: priorWindowFuller
        )
        let hasMemory = !memoryBlock.isEmpty

        let userPromptText = userPrompt(dataBlock: dataBlock, eventsBlock: eventsBlock.text, memoryBlock: memoryBlock)
        let sysPrompt = systemPrompt(
            language: language,
            isThin: stats.window.isThin,
            isOnDevice: built.isOnDevice,
            isPartial: isPartial,
            emptyBaseline: !isPartial && !compare,
            hasAttachedPhotos: !images.isEmpty,
            hasEvents: !eventsBlock.text.isEmpty,
            hasMemory: hasMemory,
            priorWindowFuller: priorWindowFuller
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
                            content: userPrompt(dataBlock: dataBlock, eventsBlock: textOnly.text, memoryBlock: memoryBlock),
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
                            hasEvents: !textOnly.text.isEmpty,
                            hasMemory: hasMemory,
                            priorWindowFuller: priorWindowFuller
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
            userNote: nil,
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

    /// Whether to append the backfill hint to a report — extracted from
    /// `generate` as a pure predicate so the trigger is unit-testable without a
    /// store or a clock.  Three of the four gates live here; the fourth,
    /// cloud-only, is `memoryBudget > 0` at the call site (the hint rides inside
    /// the memory block, which the AFM tier has none of):
    ///
    ///   1. `!isPartial` — the window this run covers must be complete; an
    ///      in-progress window's own numbers aren't settled, so it is no moment
    ///      to reflect on how an earlier one has changed;
    ///   2. `spine.statsSnapshot.window.isThin` — the spine report's *frozen*
    ///      snapshot (how the window looked WHEN THAT REPORT WAS WRITTEN) must
    ///      have been sparse.  Filling in a stretch that already read full isn't
    ///      worth a word; warming a sparse one is the whole point;
    ///   3. enough was added to the spine's window since (`backfill` over the
    ///      `ReportTuning.backfill*` floors).
    ///
    /// Asymmetric by construction: `backfill` only ever counts additions (via
    /// `Event.createdAt`), so a deletion or an edit can never trip this — the
    /// forgotten-record red line holds mechanically, not by a rule.
    static func shouldMentionBackfill(
        spine: Report,
        isPartial: Bool,
        backfill: (hours: Double, occurrences: Int)
    ) -> Bool {
        guard !isPartial, spine.statsSnapshot.window.isThin else { return false }
        return backfill.hours >= ReportTuning.backfillMinHours
            || backfill.occurrences >= ReportTuning.backfillMinOccurrences
    }

    // MARK: - Memory

    /// The most this many prior reports feed one report's memory (newest first).
    private static let memoryMaxPriorReports = 2
    /// Each USER NOTE is clipped to this many characters — a note is the highest
    /// authority in the block, but it is still context, not the report body.
    private static let memoryNoteClip = 300

    /// Selects the prior reports that become a new report's memory: same *kind*
    /// (day-span bucket, via `ReportPeriodKind`) as the window being written, and
    /// closed strictly before it opens.  The `periodEnd <= start` test admits the
    /// immediately-preceding window (whose end == this start) while excluding a
    /// same-period regeneration (whose end == this end > start) — so re-running a
    /// report never feeds itself.  Newest-created `limit` survive, newest first.
    ///
    /// Pure and static so it can be unit-tested on constructed `Report`s without a
    /// store or a clock.
    static func selectPriorReports(
        from all: [Report],
        start: Date,
        end: Date,
        calendar: Calendar,
        limit: Int = memoryMaxPriorReports
    ) -> [Report] {
        let kind = ReportPeriodKind.of(start: start, end: end, calendar: calendar)
        return all
            .filter { report in
                report.periodEnd <= start
                    && ReportPeriodKind.of(start: report.periodStart, end: report.periodEnd, calendar: calendar) == kind
            }
            // Most recent PERIOD first (createdAt only breaks ties): memory
            // wants the windows adjacent to this one — regenerating some old
            // window later must not promote it to "newest" over the period
            // that actually precedes this report.
            .sorted {
                $0.periodEnd != $1.periodEnd
                    ? $0.periodEnd > $1.periodEnd
                    : $0.createdAt > $1.createdAt
            }
            .prefix(limit)
            .map { $0 }
    }

    // Model-facing fence at the head of the memory block.  Fixed text: it draws
    // the line between "context to notice against" and "facts for this period",
    // and hands USER NOTES their authority.  English like the DATA/EVENTS blocks
    // (model-facing; the report's *output* language is set separately).
    private static let memoryFence = """
    MEMORY (from before — read it to notice what changed, then set it aside when you state facts):
    Everything below belongs to EARLIER periods — what you wrote then and the numbers you were given then. It is here so you can see what continued, changed, or faded, not to be repeated. Three rules hold no matter what: (1) every fact, number, and event about THIS period must come only from the DATA and EVENTS above — never carry a figure down from a past report or from PRIOR DATA as if it were current; (2) USER NOTES are what this person wrote back to you by hand after reading an earlier report, so they outrank anything in the old prose — if a note asks you to drop or change something, that settles it; (3) the records behind an earlier period can be filled in or corrected after its report was written, so an old report's sense of how full or empty that stretch was may simply be out of date — where its impression disagrees with the DATA, trust the DATA.
    """

    /// Assembles the MEMORY block appended after this window's DATA/EVENTS from
    /// the already-selected `priorReports` (see `selectPriorReports`).  Order:
    /// fence → USER NOTES → PRIOR DATA (the newest prior report's frozen stats
    /// *spine*, `includeCategories: false`) → PRIOR REPORTS (each report's prose).
    ///
    /// Truncation priority is a product red line and runs opposite to the emit
    /// order: USER NOTES are never dropped (added without a budget gate — in
    /// practice a handful of ≤300-char lines that never threaten the budget);
    /// when the rest won't fit, PRIOR REPORTS prose is cut from the tail first,
    /// then PRIOR DATA whole.  Every cut is announced, never silent (the
    /// `promptEvents` convention).  Returns "" when there is no memory (no prior
    /// reports, or budget 0 on the AFM tier).
    ///
    /// `priorWindowFuller` (the backfill-awareness signal, decided by
    /// `shouldMentionBackfill`) inserts one fixed hint line after USER NOTES and
    /// before PRIOR DATA when true.  It carries NO numbers, NO record count, NO
    /// `→`, and none of the words edit/add/delete — a construction constraint,
    /// not a style choice: the report may say a past stretch was fuller than it
    /// looked (a fact about their time) but must never state that records were
    /// changed (the forgotten-record red line).
    static func memoryBlock(priorReports: [Report], budget: Int, calendar: Calendar, priorWindowFuller: Bool = false) -> String {
        guard budget > 0, !priorReports.isEmpty else { return "" }
        let budgetChars = budget * ReportTuning.charsPerToken

        var sections: [String] = [memoryFence]
        // Sections are joined with "\n\n"; charge each addition its text plus the
        // 2-char separator so the running estimate matches the final string.
        var usedChars = memoryFence.count + 2

        // --- USER NOTES: mandatory, added without a budget gate. --------------
        let noteLines: [String] = priorReports.compactMap { report in
            guard let raw = report.userNote?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else { return nil }
            return "- [\(memoryPeriodLabel(report, calendar: calendar))] \(raw.prefix(memoryNoteClip))"
        }
        if !noteLines.isEmpty {
            let section = "USER NOTES (this person's own words, written back to you — highest authority):\n"
                + noteLines.joined(separator: "\n")
            sections.append(section)
            usedChars += section.count + 2   // counted, never gated
        }

        // --- PRIOR WINDOW UPDATE: the backfill hint (mandatory when set). ------
        // One line, and by construction it names no number, no record count, no
        // `→`, and nothing about editing/adding/deleting — see `memoryBlock`'s
        // doc.  Placed after USER NOTES (their word still outranks it) and before
        // PRIOR DATA.  Added like USER NOTES — counted into the estimate but never
        // budget-gated: it's the entire point of this pass, a handful of chars.
        if priorWindowFuller {
            let hint = "PRIOR WINDOW UPDATE: that stretch reads fuller now than it did when its report was written — treat the older report's sense of how full or empty it was as out of date."
            sections.append(hint)
            usedChars += hint.count + 2   // counted, never gated
        }

        // --- PRIOR DATA: the newest prior report's frozen spine, whole-or-none.
        if let latest = priorReports.first {
            let spine = latest.statsSnapshot.promptText(
                budget: budget, includeChanges: true, includeCategories: false
            )
            if !spine.isEmpty {
                let section = "PRIOR DATA (frozen when the last report was written):\n" + spine
                if usedChars + section.count + 2 <= budgetChars {
                    sections.append(section)
                    usedChars += section.count + 2
                } else {
                    let notice = "(PRIOR DATA omitted for length)"
                    sections.append(notice)
                    usedChars += notice.count + 2
                }
            }
        }

        // --- PRIOR REPORTS: prose, newest first, cut from the tail. -----------
        let proseReports = priorReports.filter {
            !$0.prose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        var keptProse = 0
        let proseHeader = "PRIOR REPORTS (what you already told them; don't repeat it):"
        for report in proseReports {
            let prose = report.prose.trimmingCharacters(in: .whitespacesAndNewlines)
            let entry = "[\(memoryPeriodLabel(report, calendar: calendar))]\n\(prose)"
            // The header is charged with (and emitted before) the first kept block.
            let headerCost = keptProse == 0 ? proseHeader.count + 2 : 0
            guard usedChars + headerCost + entry.count + 2 <= budgetChars else { break }
            if keptProse == 0 {
                sections.append(proseHeader)
                usedChars += proseHeader.count + 2
            }
            sections.append(entry)
            usedChars += entry.count + 2
            keptProse += 1
        }
        let droppedProse = proseReports.count - keptProse
        if droppedProse > 0 {
            sections.append("(+\(droppedProse) earlier report\(droppedProse == 1 ? "" : "s") omitted for length)")
        }

        return sections.joined(separator: "\n\n")
    }

    // Model-facing period label for a prior report — the day-span kind plus the
    // ISO window (end exclusive), e.g. `weekly 2026-06-23..2026-06-30`.  Fixed
    // GMT formatting keeps it stable regardless of device locale, like the DATA
    // block's WINDOW line.
    private static func memoryPeriodLabel(_ report: Report, calendar: Calendar) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        let kind: String
        switch ReportPeriodKind.of(start: report.periodStart, end: report.periodEnd, calendar: calendar) {
        case .daily: kind = "daily"
        case .weekly: kind = "weekly"
        case .monthly: kind = "monthly"
        case .custom: kind = "period"
        }
        return "\(kind) \(formatter.string(from: report.periodStart))..\(formatter.string(from: report.periodEnd))"
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
    private func systemPrompt(language: AppLanguage, isThin: Bool, isOnDevice: Bool, isPartial: Bool, emptyBaseline: Bool, hasAttachedPhotos: Bool, hasEvents: Bool, hasMemory: Bool, priorWindowFuller: Bool = false) -> String {
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

        if hasMemory {
            // Only when a MEMORY block is actually present.  A persona note, not a
            // rule list: how to write *as someone who has written to this person
            // before* — covering re-visiting, letting go, normalizing the routine,
            // holding old reads loosely, and deferring to their notes.
            prompt += """


            You've written to this person before, and some of those earlier notes are included below under MEMORY. Let them shape how you write, the way remembering a friend's last few weeks would:
            - Pick up the threads. Look back at what you noticed before and tell them how those things stand now — what held, what shifted, what turned around. Following up is the whole gift of having written before.
            - Let dead threads go. If something you once flagged has gone quiet for a stretch, don't keep poking it; not every past observation earns a sequel.
            - Don't report the weather. What happens every single period is just this person's normal, not news — reach for it only when it actually changes direction.
            - Hold your old reads loosely. Your earlier interpretations were guesses, not facts on record; if this period's data doesn't back one up, drop it — don't argue for the continuity.
            - Defer to their notes. If they wrote back asking you to leave something alone, leave it alone; their word settles it.
            Even so: every number and event you state still comes only from THIS period's DATA and EVENTS above. Memory is for what to notice, never for what happened.
            """
        }

        if priorWindowFuller {
            // Only when the backfill hint (PRIOR WINDOW UPDATE) is actually in the
            // MEMORY block — this rides on top of the memory persona above.  The
            // hard line: acknowledge a fuller past ONLY as a fact about their
            // time, NEVER as a comment on their records changing.
            prompt += """


            One more thing about that earlier stretch: looking back, it reads fuller now than the older report seemed to think. You may gently acknowledge that — but only ever as a fact about their time ("that week actually had more in it than it looked"), never as a remark about their records. Don't say anything was edited, added, filled in, or corrected, and don't reach for a before-and-after or any figures. If some past stretch instead looks emptier now, say nothing about it at all. And if their own note asked you to leave that time alone, this doesn't override them — let it go.
            """
        }

        return prompt
    }

    private func userPrompt(dataBlock: String, eventsBlock: String, memoryBlock: String) -> String {
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
        // MEMORY trails this window's own material so recency stays with the
        // present: the model reads what happened first, then what came before.
        // The block carries its own fence header.
        if !memoryBlock.isEmpty {
            sections.append(memoryBlock)
        }
        return sections.joined(separator: "\n\n")
    }
}
