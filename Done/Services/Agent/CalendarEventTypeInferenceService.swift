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

/// Shared gate for every automatic (non-explicit) local type suggestion,
/// whether it fires while typing or after save. gh#182 found most of the
/// local-scoring entry points wiring their own hand-rolled check (or none
/// at all) instead of routing through here — every one of them must call
/// this, so there is one place that decides the answer instead of a
/// parallel check per call site. (The LLM autofill path is a separate
/// mechanism — see `calendarReminderScheduleAutofillTypeTitle` in
/// CalendarPageView.swift — and does not call this.)
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

/// One event's query-INDEPENDENT normalized text, precomputed once so the
/// while-typing suggestion pass (gh#37) does not re-normalize the entire
/// event corpus (dogfood ~2690 rows) on every keystroke. Built lazily and
/// reused across keystrokes by `EventStore.calendarTypeSuggestionCorpus()`,
/// keyed on `searchCorpusRevision`.
///
/// It holds ONLY what depends on the event itself, never on the query text
/// or the current type library:
///   * `rawType` — the event's stored `type` STRING, un-resolved.
///   * `normalizedTitle` / `normalizedEventText` — the two folded strings
///     the scorer compares against.
///   * `titleTokens` / `eventTokens` — their token sets.
///   * `eventID` — so a caller (post-save inference) can exclude one row.
///
/// gh#37 guardrail G1 lives in what this deliberately does NOT hold: a
/// RESOLVED type. `event.type` → an available-type title is computed at
/// QUERY time (`calendarHistoricalTypeSuggestion(...corpus:...)` calls
/// `calendarResolvedAvailableTypeTitle` against the CURRENT `availableTypes`),
/// because the type library (`EventTypeTemplateStore.add/update/remove`)
/// changes WITHOUT bumping `searchCorpusRevision` — so a resolved type baked
/// into this revision-keyed entry would go stale (suggest a just-deleted
/// type, or fail to suggest a just-added one) until the next unrelated event
/// write happened to rebuild the corpus.
struct CalendarTypeSuggestionCorpusEntry: Equatable {
    let eventID: UUID
    let rawType: String
    let normalizedTitle: String
    let normalizedEventText: String
    let titleTokens: Set<String>
    let eventTokens: Set<String>

    /// Returns `nil` for an event whose combined title+note normalizes to
    /// empty — exactly the `guard !normalizedEventText.isEmpty else { continue }`
    /// the inline scorer performed. Such an event contributed nothing to any
    /// query before and is simply absent from the corpus now, so no query's
    /// answer changes.
    init?(event: Event) {
        let normalizedTitle = calendarNormalizedTypeSuggestionText(event.title)
        let normalizedEventText = calendarNormalizedTypeSuggestionText(
            calendarTypeSuggestionRawText(title: event.title, note: event.note)
        )
        guard !normalizedEventText.isEmpty else { return nil }
        self.eventID = event.id
        self.rawType = event.type
        self.normalizedTitle = normalizedTitle
        self.normalizedEventText = normalizedEventText
        self.titleTokens = Set(calendarTypeSuggestionTokens(normalizedTitle))
        self.eventTokens = Set(calendarTypeSuggestionTokens(normalizedEventText))
    }
}

/// Pure-`[Event]` overload kept for API/behavior stability (gh#37 G4): the
/// existing `DoneTests` contracts still call the suggestion functions with a
/// raw event array and must run the real scoring. It builds the corpus inline
/// (identical normalization) and delegates to the corpus-based core below, so
/// there is one scorer, not two that can drift.
func calendarHistoricalTypeSuggestion(
    rawText: String,
    availableTypes: [String],
    events: [Event]
) -> CalendarEventTypeSuggestion? {
    calendarHistoricalTypeSuggestion(
        rawText: rawText,
        availableTypes: availableTypes,
        corpus: events.compactMap(CalendarTypeSuggestionCorpusEntry.init)
    )
}

/// Corpus-based core. `corpus` carries the per-event normalization already
/// done; `availableTypes` is resolved FRESH here every call (gh#37 G1).
/// `excludingEventID` skips one row without allocating a filtered copy —
/// the post-save path (gh#37 G2) passes the just-saved event's id so an
/// event does not match its own identical title back to itself.
func calendarHistoricalTypeSuggestion(
    rawText: String,
    availableTypes: [String],
    corpus: [CalendarTypeSuggestionCorpusEntry],
    excludingEventID: UUID? = nil
) -> CalendarEventTypeSuggestion? {
    let normalizedText = calendarNormalizedTypeSuggestionText(rawText)
    guard !normalizedText.isEmpty else { return nil }

    let queryTokens = Set(calendarTypeSuggestionTokens(normalizedText))
    guard !queryTokens.isEmpty else { return nil }

    var scoreByType: [String: Double] = [:]
    var bestSingleScoreByType: [String: Double] = [:]

    for entry in corpus {
        if let excludingEventID, entry.eventID == excludingEventID { continue }
        guard let resolvedTypeTitle = calendarResolvedAvailableTypeTitle(
            entry.rawType,
            availableTypes: availableTypes
        ) else { continue }

        let normalizedTitle = entry.normalizedTitle
        let normalizedEventText = entry.normalizedEventText
        let titleTokens = entry.titleTokens
        let eventTokens = entry.eventTokens

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

/// Pure-`[Event]` overload (gh#37 G4): builds the corpus once and delegates
/// to the corpus-based core, so the existing tests exercise the same scorer
/// the store path does.
func calendarPreferredLocalTypeSuggestion(
    rawText: String,
    availableTypes: [String],
    historicalEvents: [Event]
) -> CalendarEventTypeSuggestion? {
    calendarPreferredLocalTypeSuggestion(
        rawText: rawText,
        availableTypes: availableTypes,
        corpus: historicalEvents.compactMap(CalendarTypeSuggestionCorpusEntry.init)
    )
}

/// Corpus-based core shared by the five while-typing / post-save call sites
/// via `EventStore.calendarTypeSuggestion(...)` (gh#37). The keyword pass is
/// query-only (no corpus), so nothing here caches anything type-library
/// dependent — see the corpus entry's G1 note.
func calendarPreferredLocalTypeSuggestion(
    rawText: String,
    availableTypes: [String],
    corpus: [CalendarTypeSuggestionCorpusEntry],
    excludingEventID: UUID? = nil
) -> CalendarEventTypeSuggestion? {
    let historicalSuggestion = calendarHistoricalTypeSuggestion(
        rawText: rawText,
        availableTypes: availableTypes,
        corpus: corpus,
        excludingEventID: excludingEventID
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

/// gh#37 G5 — the verification hook for the corpus cache.
///
/// The while-typing suggestion pass runs on a main-actor `Task` off the
/// commit path, so Fix Watch's `firstFrameAfterCommitMs` cannot see it. This
/// is the dedicated seam that can: when enabled, every pass appends one line
/// to the `DiagnosticTrail` (durable, exportable, survives a relaunch — the
/// same sink `DraftSlot` uses) recording
/// `events`, `cacheHit`, `availableTypesGen`, and `elapsedUs`. A large-corpus
/// harness scenario reads the `elapsedUs` sequence off the trail: the first
/// pass after any store write is a build (high, `cacheHit=false`), the
/// keystrokes that follow are cache hits (low, `cacheHit=true`). If the two
/// never separate, the cache is being invalidated per keystroke by
/// background writes (the G3 hazard) — visible here, nowhere else.
///
/// `availableTypesGen` is the SECOND number G5 requires: a fingerprint of the
/// type library this pass resolved against. Because the corpus is keyed on
/// `searchCorpusRevision` and the type library is NOT (G1), a stale-type miss
/// would otherwise be silent; two passes whose `availableTypesGen` differs
/// prove the resolution used the current library, and a suggestion echoing a
/// type absent from the logged generation is the bug's signature.
///
/// Gated OFF by default (`enabledDefaultsKey`): a `DiagnosticTrail.record` is
/// a synchronous `write(2)`, and this fires per typing-pause — acceptable
/// only while a measurement session is explicitly armed. The format is split
/// out as a pure `line(...)` so its content is pinned by fixture instead of
/// asserted against the shared trail file.
enum CalendarTypeSuggestionDiagnostics {
    static let trailCategory = "TypeSuggestCorpus"
    static let enabledDefaultsKey = "diag.typeSuggestionCorpus.enabled"

    static func isEnabled(_ defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: enabledDefaultsKey)
    }

    /// Process-stable fingerprint of the current type library (gh#37 G5).
    /// FNV-1a over the order-preserving join of the titles — deterministic
    /// across launches (unlike Swift's per-process-seeded `Hasher`), so a
    /// trail exported from one run is comparable to another, and
    /// order-sensitive because `calendarResolvedAvailableTypeTitle` returns
    /// the FIRST title that normalizes-equal, so a reorder is a resolution
    /// change.
    static func availableTypesGeneration(_ availableTypes: [String]) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        // U+0001 as separator: cannot occur inside a real type title, so
        // ["ab","c"] and ["a","bc"] never collide.
        for byte in availableTypes.joined(separator: "\u{1}").utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }

    /// The exact trail line for one pass. Pure, so tests assert on it
    /// without touching the process-global trail file.
    static func line(
        events: Int,
        corpus: Int,
        cacheHit: Bool,
        availableTypes: [String],
        elapsedUs: UInt64
    ) -> String {
        "pass events=\(events) corpus=\(corpus) cacheHit=\(cacheHit)"
            + " availableTypesGen=\(availableTypesGeneration(availableTypes))"
            + " types=\(availableTypes.count) elapsedUs=\(elapsedUs)"
    }

    static func record(
        events: Int,
        corpus: Int,
        cacheHit: Bool,
        availableTypes: [String],
        elapsedUs: UInt64,
        defaults: UserDefaults
    ) {
        guard isEnabled(defaults) else { return }
        DiagnosticTrail.record(
            trailCategory,
            line(
                events: events,
                corpus: corpus,
                cacheHit: cacheHit,
                availableTypes: availableTypes,
                elapsedUs: elapsedUs
            )
        )
    }
}

@MainActor
final class CalendarEventTypeInferenceService {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
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

        // Local-only: historical title match first, keyword rules second.
        // The LLM fallback that used to run when both miss was removed — it
        // fired a network call after every untyped save, and its write-back
        // re-triggered every calendarEventRecorded listener; the local paths
        // cover the common cases and improve as history accumulates.  An
        // event neither path can place simply keeps its current type.
        // gh#37 G2: the just-saved event is already in `rawCalendarEvents`
        // (its write bumped the corpus revision, so the shared corpus rebuilt
        // to include it). `excludingEventID` skips it in-place — the old
        // `.filter { $0.id != event.id }` allocated a whole corpus copy every
        // post-save to achieve the same skip. Routes through the shared
        // revision-keyed corpus so this pass reuses the index the while-typing
        // path just built, and emits the same G5 verification line.
        guard let localSuggestion = store.calendarTypeSuggestion(
            rawText: rawText,
            availableTypes: availableTypes,
            excludingEventID: event.id
        ) else { return }
        await applySuggestion(
            localSuggestion,
            eventID: event.id,
            originalTypeTitle: event.type,
            store: store,
            availableTypes: availableTypes
        )
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
