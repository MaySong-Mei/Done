import Foundation
import NaturalLanguage

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

/// Words for type suggestion: `NLTokenizer` word segmentation (so a Chinese
/// title with no spaces — 「写论文第二章」 → 写 / 论文 / 第二 / 章 — becomes
/// words instead of one opaque token), each folded the same way
/// `calendarNormalizedTypeSuggestionText` folds, punctuation dropped.
func calendarTypeSuggestionWords(_ text: String) -> [String] {
    guard !text.isEmpty else { return [] }
    // Creating an NLTokenizer costs ~25x a tokenize, and a corpus build calls
    // this for every event — so each thread keeps one.
    let key = "calendarTypeSuggestionWords.tokenizer"
    let tokenizer: NLTokenizer
    if let kept = Thread.current.threadDictionary[key] as? NLTokenizer {
        tokenizer = kept
    } else {
        tokenizer = NLTokenizer(unit: .word)
        Thread.current.threadDictionary[key] = tokenizer
    }
    tokenizer.string = text
    var words: [String] = []
    tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
        let folded = calendarNormalizedTypeSuggestionText(String(text[range]))
        words.append(contentsOf: calendarTypeSuggestionTokens(folded))
        return true
    }
    return words
}

/// Adjacent-word pairs. A word like "home" says little alone ("drive home"
/// vs "run home"); the pair is what carries the direction.
func calendarTypeSuggestionBigrams(_ words: [String]) -> [String] {
    guard words.count >= 2 else { return [] }
    return (1..<words.count).map { "\(words[$0 - 1]) \(words[$0])" }
}

private func calendarTypeSuggestionIsCJK(_ word: String) -> Bool {
    word.unicodeScalars.contains { scalar in
        switch scalar.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF:
            return true
        default:
            return false
        }
    }
}

/// A word too short to mean anything on its own: one Latin letter or digit.
/// One CJK character is a real word (写, 读, 练), so it stays.
private func calendarTypeSuggestionIsTooShort(_ word: String) -> Bool {
    word.count < 2 && !calendarTypeSuggestionIsCJK(word)
}

/// One event's query-INDEPENDENT words, precomputed once so the while-typing
/// suggestion pass (gh#37) does not re-segment the entire event corpus
/// (dogfood ~2690 rows) on every keystroke. Built lazily and reused across
/// keystrokes by `EventStore.calendarTypeSuggestionCorpus()`, keyed on
/// `searchCorpusRevision`; a rebuild reuses an unchanged row's entry rather
/// than tokenizing it again.
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
    let sourceTitle: String
    let sourceNote: String
    /// The event's first start, for recency weighting; nil counts as now.
    let date: Date?
    /// Title words joined by a space — compared whole for the exact-title rule.
    let normalizedTitle: String
    let titleWords: [String]
    /// Title words plus their adjacent pairs.
    let titleFeatures: Set<String>
    let noteWords: Set<String>

    /// Returns `nil` for an event whose title and note hold no words: it
    /// can match nothing, so it is simply absent from the corpus.
    init?(event: Event) {
        let titleWords = calendarTypeSuggestionWords(event.title)
        let noteWords = calendarTypeSuggestionWords(event.note)
        guard !titleWords.isEmpty || !noteWords.isEmpty else { return nil }
        self.eventID = event.id
        self.rawType = event.type
        self.sourceTitle = event.title
        self.sourceNote = event.note
        self.date = event.timeRanges.first?.start
        self.normalizedTitle = titleWords.joined(separator: " ")
        self.titleWords = titleWords
        self.titleFeatures = Set(titleWords).union(calendarTypeSuggestionBigrams(titleWords))
        self.noteWords = Set(noteWords)
    }

    /// Whether this entry still describes `event` — the rebuild's reuse test.
    func describes(_ event: Event) -> Bool {
        eventID == event.id && rawType == event.type && sourceTitle == event.title
            && sourceNote == event.note && date == event.timeRanges.first?.start
    }
}

/// Pure-`[Event]` overload kept for API/behavior stability (gh#37 G4): the
/// existing `DoneTests` contracts still call the suggestion functions with a
/// raw event array and must run the real scoring. It builds the corpus inline
/// and delegates to the corpus-based core below, so there is one scorer, not
/// two that can drift.
func calendarHistoricalTypeSuggestion(
    rawText: String,
    availableTypes: [String],
    events: [Event],
    now: Date = Date()
) -> CalendarEventTypeSuggestion? {
    calendarHistoricalTypeSuggestion(
        rawText: rawText,
        availableTypes: availableTypes,
        corpus: events.compactMap(CalendarTypeSuggestionCorpusEntry.init),
        now: now
    )
}

/// The tuning of the historical scorer. The cases these numbers decide are
/// the "Words" section of CalendarEventTypeInferenceServiceTests.
enum CalendarTypeSuggestionTuning {
    /// An event this many days old counts half as much as one from today.
    static let halfLifeDays: Double = 90
    /// A word is predictive once this share of its (recency-weighted) uses
    /// fall on one type; below it, it only points a direction.
    static let anchorShare: Double = 0.8
    /// The share at or below which a word is purely directional.
    static let directionalShare: Double = 0.5
    /// How much a purely directional word still votes, relative to a fully
    /// predictive one.
    static let directionalVote: Double = 0.2
    /// The winner must have at least this many times the runner-up's votes.
    static let winnerLead: Double = 2
    static let pairWeight: Double = 1.3
    static let noteWeight: Double = 0.5
    /// A half-typed last word matched only as a prefix of a known word.
    static let prefixWeight: Double = 0.7
}

/// Corpus-based core. `corpus` carries the per-event words already split;
/// `availableTypes` is resolved FRESH here every call (gh#37 G1).
/// `excludingEventID` skips one row without allocating a filtered copy —
/// the post-save path (gh#37 G2) passes the just-saved event's id so an
/// event does not match its own identical title back to itself.
///
/// How it decides:
/// 1. Same title as past events, and they agree (`anchorShare`) → that type.
/// 2. Otherwise every query word (and adjacent pair, and a half-typed last
///    word as a prefix) looks up which types it has appeared under. A word
///    whose uses mostly fall on one type is predictive ("gym"); one spread
///    across types only points a direction ("home") and votes weakly. Older
///    events count less, and a word seen once counts less than one seen often.
/// 3. The top type is returned only if some predictive word backs it AND it
///    leads the runner-up clearly. Otherwise nil — directional words alone
///    never decide.
func calendarHistoricalTypeSuggestion(
    rawText: String,
    availableTypes: [String],
    corpus: [CalendarTypeSuggestionCorpusEntry],
    excludingEventID: UUID? = nil,
    now: Date = Date()
) -> CalendarEventTypeSuggestion? {
    calendarHistoricalTypeEvidence(
        rawText: rawText,
        availableTypes: availableTypes,
        corpus: corpus,
        excludingEventID: excludingEventID,
        now: now
    ).suggestion
}

/// The historical scorer's answer plus whether history had anything to say
/// about the query at all — the keyword table only fills in when it did not.
struct CalendarHistoricalTypeEvidence {
    var suggestion: CalendarEventTypeSuggestion?
    var historyMatchedAnyWord: Bool
}

func calendarHistoricalTypeEvidence(
    rawText: String,
    availableTypes: [String],
    corpus: [CalendarTypeSuggestionCorpusEntry],
    excludingEventID: UUID? = nil,
    now: Date = Date()
) -> CalendarHistoricalTypeEvidence {
    typealias Tuning = CalendarTypeSuggestionTuning
    let silent = CalendarHistoricalTypeEvidence(suggestion: nil, historyMatchedAnyWord: false)

    let queryWords = calendarTypeSuggestionWords(rawText)
    guard !queryWords.isEmpty else { return silent }

    // The last word is still being typed unless the text ends past it.
    let endsMidWord = rawText.unicodeScalars.last.map(CharacterSet.alphanumerics.contains) ?? false
    let completeWords = endsMidWord ? Array(queryWords.dropLast()) : queryWords
    let openWord = endsMidWord ? queryWords.last : nil

    // Rows whose type is in the current library, with their recency weight.
    var rows: [(entry: CalendarTypeSuggestionCorpusEntry, type: String, recency: Double)] = []
    rows.reserveCapacity(corpus.count)
    for entry in corpus {
        if let excludingEventID, entry.eventID == excludingEventID { continue }
        guard let type = calendarResolvedAvailableTypeTitle(
            entry.rawType,
            availableTypes: availableTypes
        ) else { continue }
        let ageDays = entry.date.map { max(0, now.timeIntervalSince($0) / 86_400) } ?? 0
        rows.append((entry, type, pow(0.5, ageDays / Tuning.halfLifeDays)))
    }
    guard !rows.isEmpty else { return silent }

    // 1. Exact title.
    let queryTitle = queryWords.joined(separator: " ")
    var exactByType: [String: Double] = [:]
    for row in rows where row.entry.normalizedTitle == queryTitle {
        exactByType[row.type, default: 0] += row.recency
    }
    let exactTotal = exactByType.values.reduce(0, +)
    if exactTotal > 0,
       let best = calendarTypeSuggestionTop(exactByType, order: availableTypes),
       best.value / exactTotal >= Tuning.anchorShare {
        return CalendarHistoricalTypeEvidence(
            suggestion: CalendarEventTypeSuggestion(typeTitle: best.key, confidence: 0.97, source: .local),
            historyMatchedAnyWord: true
        )
    }

    // 2. Word votes. Each feature is a predicate over a row plus a weight.
    var features: [(weight: Double, matches: (CalendarTypeSuggestionCorpusEntry) -> Double)] = []
    var seen: Set<String> = []
    for word in completeWords where !calendarTypeSuggestionIsTooShort(word) && seen.insert(word).inserted {
        features.append((1, { entry in
            entry.titleFeatures.contains(word) ? 1 : (entry.noteWords.contains(word) ? Tuning.noteWeight : 0)
        }))
    }
    // Pairs include the open word: a half-typed word simply matches no pair.
    for pair in calendarTypeSuggestionBigrams(queryWords) where seen.insert(pair).inserted {
        features.append((Tuning.pairWeight, { $0.titleFeatures.contains(pair) ? 1 : 0 }))
    }
    if let openWord, !calendarTypeSuggestionIsTooShort(openWord) {
        let isKnownWord = rows.contains { $0.entry.titleFeatures.contains(openWord) }
        features.append((isKnownWord ? 1 : Tuning.prefixWeight, { entry in
            if entry.titleWords.contains(where: { $0.hasPrefix(openWord) }) { return 1 }
            return entry.noteWords.contains(where: { $0.hasPrefix(openWord) }) ? Tuning.noteWeight : 0
        }))
    }

    var votes: [String: Double] = [:]
    var anchoredTypes: Set<String> = []
    var matchedAny = false
    for feature in features {
        var recencyByType: [String: Double] = [:]
        var uses = 0.0
        for row in rows {
            let match = feature.matches(row.entry)
            guard match > 0 else { continue }
            recencyByType[row.type, default: 0] += match * row.recency
            uses += match
        }
        let total = recencyByType.values.reduce(0, +)
        guard uses > 0, total > 0,
              let top = calendarTypeSuggestionTop(recencyByType, order: availableTypes) else { continue }
        matchedAny = true

        let topShare = top.value / total
        let predictiveness = min(max(
            (topShare - Tuning.directionalShare) / (1 - Tuning.directionalShare), 0
        ), 1)
        let support = uses / (uses + 1)
        let strength = feature.weight * support
            * (Tuning.directionalVote + (1 - Tuning.directionalVote) * predictiveness)
        for (type, value) in recencyByType {
            votes[type, default: 0] += strength * value / total
        }
        if topShare >= Tuning.anchorShare {
            anchoredTypes.insert(top.key)
        }
    }

    // 3. Decide.
    guard let winner = calendarTypeSuggestionTop(votes, order: availableTypes),
          anchoredTypes.contains(winner.key) else {
        return CalendarHistoricalTypeEvidence(suggestion: nil, historyMatchedAnyWord: matchedAny)
    }
    let runnerUp = votes.filter { $0.key != winner.key }.values.max() ?? 0
    guard winner.value >= runnerUp * Tuning.winnerLead else {
        return CalendarHistoricalTypeEvidence(suggestion: nil, historyMatchedAnyWord: matchedAny)
    }
    let voteTotal = votes.values.reduce(0, +)
    return CalendarHistoricalTypeEvidence(
        suggestion: CalendarEventTypeSuggestion(
            typeTitle: winner.key,
            confidence: min(0.95, winner.value / voteTotal),
            source: .local
        ),
        historyMatchedAnyWord: true
    )
}

/// The highest-valued key; ties go to the type listed first in the library,
/// so the answer never depends on dictionary order.
private func calendarTypeSuggestionTop(
    _ values: [String: Double],
    order: [String]
) -> (key: String, value: Double)? {
    var best: (key: String, value: Double)?
    for type in order {
        guard let value = values[type], value > 0 else { continue }
        if best == nil || value > best!.value {
            best = (type, value)
        }
    }
    return best
}

/// The user typed a type's own name as words ("study session" with a
/// "Study" type, 「学习计划」 with 「学习」). Taken when history cannot decide.
func calendarTypeNameMentionSuggestion(
    rawText: String,
    availableTypes: [String]
) -> CalendarEventTypeSuggestion? {
    let queryWords = Set(calendarTypeSuggestionWords(rawText))
    guard !queryWords.isEmpty else { return nil }
    for availableType in availableTypes {
        let typeWords = calendarTypeSuggestionWords(availableType)
        guard !typeWords.isEmpty,
              !(typeWords.count == 1 && calendarTypeSuggestionIsTooShort(typeWords[0])) else { continue }
        if typeWords.allSatisfy(queryWords.contains) {
            return CalendarEventTypeSuggestion(typeTitle: availableType, confidence: 0.9, source: .local)
        }
    }
    return nil
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
    historicalEvents: [Event],
    now: Date = Date()
) -> CalendarEventTypeSuggestion? {
    calendarPreferredLocalTypeSuggestion(
        rawText: rawText,
        availableTypes: availableTypes,
        corpus: historicalEvents.compactMap(CalendarTypeSuggestionCorpusEntry.init),
        now: now
    )
}

/// Corpus-based core shared by the five while-typing / post-save call sites
/// via `EventStore.calendarTypeSuggestion(...)` (gh#37). Returning nil means
/// "not sure — leave the type alone"; every caller already treats it so.
///
/// Order: history decides when it can. If it cannot, a type named outright
/// in the text wins. The built-in keyword table (and type-name prefixes)
/// only speak when history has never seen any of these words — it is the
/// cold start, and a user's own history overrules it.
func calendarPreferredLocalTypeSuggestion(
    rawText: String,
    availableTypes: [String],
    corpus: [CalendarTypeSuggestionCorpusEntry],
    excludingEventID: UUID? = nil,
    now: Date = Date()
) -> CalendarEventTypeSuggestion? {
    let history = calendarHistoricalTypeEvidence(
        rawText: rawText,
        availableTypes: availableTypes,
        corpus: corpus,
        excludingEventID: excludingEventID,
        now: now
    )
    if let suggestion = history.suggestion {
        return suggestion
    }
    if let mention = calendarTypeNameMentionSuggestion(rawText: rawText, availableTypes: availableTypes) {
        return mention
    }
    guard !history.historyMatchedAnyWord else { return nil }
    return calendarKeywordTypeSuggestion(rawText: rawText, availableTypes: availableTypes)
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
