import XCTest
@testable import Done

/// Independent QA for gh#37 (type-suggestion corpus cache). Written WITHOUT
/// reusing the implementer's assertions: every expected suggestion / confidence
/// below is derived by hand from the scorer in
/// `CalendarEventTypeInferenceService.swift` and pinned as a literal, so a
/// silent scorer change is caught here, not only "the two sides agree".
///
/// Each test drives the STORE path (`EventStore.calendarTypeSuggestion(...)`)
/// on its own non-seeding store, because the shared sample-seeded store places
/// stray matches under common titles. These tests are the mutation tripwires:
///   * M1 — bake resolvedType into the revision-keyed corpus  → killed by
///           `testTemplateLibraryChangeReflectedWithoutRebuild`
///   * M2 — drop post-save self-exclusion                     → killed by
///           `testPostSaveSelfMatchExcludedThroughCache`
///   * M3 — cache ignores searchCorpusRevision (never stale)  → killed by
///           `testCorpusInvalidatesOnStoreWriteSoNewEventBecomesSuggestable`
///   * M4 — normalize every keystroke (cache not wired)       → killed by
///           `testCorpusBuildsOncePerRevisionAcrossKeystrokes`
@MainActor
final class CalendarTypeSuggestionCacheQATests: XCTestCase {
    private var suites: [String] = []
    private let calendar = Calendar(identifier: .gregorian)

    override func tearDown() {
        for suite in suites { TestStorage.tearDown(suite) }
        suites = []
        super.tearDown()
    }

    // MARK: fixtures

    private func makeEmptyStore(_ label: String) -> (store: EventStore, defaults: UserDefaults) {
        let suite = "CTSQA-\(label)-\(UUID().uuidString)"
        suites.append(suite)
        TestStorage.reset(suite)
        let defaults = UserDefaults(suiteName: suite)!
        let store = EventStore(
            defaults: defaults,
            storage: .isolated(name: suite),
            seedsSampleDataIfEmpty: false
        )
        return (store, defaults)
    }

    @discardableResult
    private func seed(_ store: EventStore, title: String, note: String = "", type: String, day: Int = 1) -> Event {
        let event = Event(
            title: title,
            note: note,
            location: "",
            timeRanges: [Event.TimeRange(
                start: date(2026, 3, day, 9, 0),
                end: date(2026, 3, day, 10, 0)
            )],
            type: type
        )
        store.addCalendarEvent(event)
        return event
    }

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    // MARK: - positive control + independent arithmetic
    //
    // Vocabulary chosen to touch NO keyword family ("grocery"/"planning"/
    // "session" are absent from work/study/exercise/sleep lists), so the
    // keyword pass contributes nothing and the number under test is purely the
    // historical scorer's — a positive control whose zero-elsewhere makes the
    // suggestion meaningful.

    /// POSITIVE CONTROL: an exact historical title match must yield a
    /// suggestion (a suite that produced only nils would prove nothing). Query
    /// text == stored title → the scorer's equality branch sets score 0.99,
    /// aggregate == single == 0.99, confidence = min(0.97, 0.99) = 0.97.
    func testExactHistoricalMatchProducesSuggestion_positiveControl() {
        let (store, _) = makeEmptyStore("poscontrol")
        seed(store, title: "Grocery planning", type: "Chores")

        let s = store.calendarTypeSuggestion(
            rawText: "Grocery planning",
            availableTypes: ["Chores", "Work", "Study"]
        )
        XCTAssertEqual(s?.typeTitle, "Chores")
        XCTAssertEqual(s?.source, .local)
        XCTAssertEqual(s?.confidence ?? 0, 0.97, accuracy: 1e-9,
                       "exact match saturates to 0.99 single-score, clamped to the 0.97 confidence ceiling")
    }

    /// INDEPENDENT ARITHMETIC: a partial overlap where I compute the exact
    /// confidence from the scorer by hand.
    ///
    /// Stored: title "Grocery planning session" (titleTokens =
    /// {grocery,planning,session}, count 3), note empty so eventTokens == the
    /// same set. Query "Grocery planning" (queryTokens {grocery,planning},
    /// count 2), normalizedText "grocery planning".
    ///
    /// Every contributing branch tops out at 0.9:
    ///   • title `contains`: "grocery planning session".contains("grocery
    ///     planning") → 0.9
    ///   • title prefix (hasPrefix, len≥4) → 0.9
    ///   • title-token overlap: 0.58 + (2/3)·0.22 + (2/2)·0.15 = 0.8767 (< 0.9)
    ///   • title prefix-token (both match, ==queryTokens.count≥2) → 0.83 (< 0.9)
    ///   • event-token overlap (≥2 & coverage 2/3 ≥ .5) → 0.82 (< 0.9)
    /// so score = 0.9. One entry ⇒ aggregate = single = 0.9;
    /// confidence = min(0.97, 0.9 + min(max(0,0)·.08, .06)) = 0.9.
    func testPartialOverlapConfidenceMatchesHandDerivation() {
        let (store, _) = makeEmptyStore("arith")
        seed(store, title: "Grocery planning session", type: "Chores")

        let s = store.calendarTypeSuggestion(
            rawText: "Grocery planning",
            availableTypes: ["Chores", "Work", "Study"]
        )
        XCTAssertEqual(s?.typeTitle, "Chores")
        XCTAssertEqual(s?.confidence ?? -1, 0.9, accuracy: 1e-9,
                       "hand-derived: dominant branch is the title contains/prefix at 0.9, single==aggregate")
    }

    // MARK: - M4: build once per revision, not per keystroke

    /// The cache's whole reason to exist. A correctness assertion cannot see a
    /// per-keystroke rebuild (the answer is identical), so this is pinned by
    /// the build counter. Kills M4 (normalization not memoized) and half of M3.
    func testCorpusBuildsOncePerRevisionAcrossKeystrokes() {
        let (store, _) = makeEmptyStore("buildcount")
        seed(store, title: "Grocery planning", type: "Chores")

        XCTAssertEqual(store.typeSuggestionCorpusBuildCount, 0)

        // Three settled keystrokes, no write between them: exactly one build.
        _ = store.calendarTypeSuggestion(rawText: "gro", availableTypes: ["Chores"])
        XCTAssertEqual(store.typeSuggestionCorpusBuildCount, 1)
        _ = store.calendarTypeSuggestion(rawText: "groc", availableTypes: ["Chores"])
        _ = store.calendarTypeSuggestion(rawText: "grocery", availableTypes: ["Chores"])
        XCTAssertEqual(store.typeSuggestionCorpusBuildCount, 1,
                       "keystrokes that wrote nothing must all reuse the one corpus build")
    }

    // MARK: - M3: revision keying (cache must go stale on a store write)

    /// After a store write, the corpus MUST rebuild so a brand-new event is
    /// suggestable. Uses a title only the newly-written row can match: if the
    /// cache ignored searchCorpusRevision (M3), the pre-write corpus would be
    /// reused and the query would miss. Also pins the build counter increment.
    func testCorpusInvalidatesOnStoreWriteSoNewEventBecomesSuggestable() {
        let (store, _) = makeEmptyStore("invalidate")
        seed(store, title: "Grocery planning", type: "Chores")

        // Warm the corpus; "Blueprint drafting" is not present yet.
        let before = store.calendarTypeSuggestion(
            rawText: "Blueprint drafting",
            availableTypes: ["Chores", "Work"]
        )
        XCTAssertNil(before, "nothing in the corpus matches 'Blueprint drafting' yet")
        let buildsAfterWarm = store.typeSuggestionCorpusBuildCount

        // A store write bumps searchCorpusRevision.
        seed(store, title: "Blueprint drafting", type: "Work")

        let after = store.calendarTypeSuggestion(
            rawText: "Blueprint drafting",
            availableTypes: ["Chores", "Work"]
        )
        XCTAssertEqual(after?.typeTitle, "Work",
                       "the write must invalidate the corpus so the new row is scored")
        XCTAssertGreaterThan(store.typeSuggestionCorpusBuildCount, buildsAfterWarm,
                             "a revision bump must force exactly one rebuild on the next pass")
    }

    // MARK: - M1: resolvedType is NOT baked into the revision-keyed corpus

    /// gh#37 G1 through the cache. Same cached corpus (build count unchanged),
    /// a wider `availableTypes` on the second pass, a different answer — proving
    /// the entry stores the RAW type and resolves against the CURRENT library
    /// every query. The type library (EventTypeTemplateStore.add/remove) does
    /// NOT bump searchCorpusRevision, so a resolved type baked into the corpus
    /// (M1) would still miss on pass B because no write rebuilt it.
    ///
    /// Arithmetic: "Neighborhood walk" == stored title → 0.99 → 0.97 once
    /// "Exercise" is resolvable; nil while it is not in the library.
    func testTemplateLibraryChangeReflectedWithoutRebuild() {
        let (store, _) = makeEmptyStore("librarychange")
        seed(store, title: "Neighborhood walk", type: "Exercise")

        let passA = store.calendarTypeSuggestion(
            rawText: "Neighborhood walk",
            availableTypes: ["Study", "Work"]
        )
        XCTAssertNil(passA, "'Exercise' is outside the library, so its row resolves to nothing")
        let buildsAfterA = store.typeSuggestionCorpusBuildCount

        let passB = store.calendarTypeSuggestion(
            rawText: "Neighborhood walk",
            availableTypes: ["Study", "Work", "Exercise"]
        )
        XCTAssertEqual(passB?.typeTitle, "Exercise")
        XCTAssertEqual(passB?.confidence ?? 0, 0.97, accuracy: 1e-9)
        XCTAssertEqual(store.typeSuggestionCorpusBuildCount, buildsAfterA,
                       "the answer changed with the library while the SAME cached corpus was reused (no write happened)")
    }

    /// G4 companion, through the STORE cache: a stored row whose type is
    /// outside the current library must never be echoed back — the store-path
    /// analog of the pure-function contract at
    /// `CalendarEventTypeInferenceServiceTests.testHistoricalSuggestionIgnoresTypesOutsideCurrentTemplateLibrary`.
    func testTypeOutsideLibraryNeverSuggestedThroughStoreCache() {
        let (store, _) = makeEmptyStore("outsidelib")
        seed(store, title: "Neighborhood walk", note: "", type: "Personal")

        let s = store.calendarTypeSuggestion(
            rawText: "Neighborhood walk",
            availableTypes: ["Study", "Work", "Exercise"]
        )
        if let s {
            XCTAssertNotEqual(s.typeTitle, "Personal", "'Personal' is not in the current library")
            XCTAssertTrue(["Study", "Work", "Exercise"].contains(s.typeTitle))
        }
    }

    // MARK: - M2: post-save self-exclusion

    /// gh#37 G2 through the cache. The shared corpus includes the just-saved
    /// row (its write rebuilt the corpus). Without exclusion the row matches
    /// its own identical title back to itself at 0.99 → "Work"; the post-save
    /// path passes `excludingEventID` to skip exactly that row. Dropping the
    /// skip (M2) makes the excluded query return "Work" instead of nil.
    func testPostSaveSelfMatchExcludedThroughCache() {
        let (store, _) = makeEmptyStore("selfmatch")
        let e = seed(store, title: "Quarterly synthesis", type: "Work")

        let notExcluded = store.calendarTypeSuggestion(
            rawText: "Quarterly synthesis",
            availableTypes: ["Study", "Work"]
        )
        XCTAssertEqual(notExcluded?.typeTitle, "Work",
                       "the identical-title row scores 0.99 against itself when not excluded")

        let excluded = store.calendarTypeSuggestion(
            rawText: "Quarterly synthesis",
            availableTypes: ["Study", "Work"],
            excludingEventID: e.id
        )
        XCTAssertNil(excluded,
                     "excluding the only matching row removes the self-match; no other source places this text")
    }

    // MARK: - G3: cache-hit resilience under interleaved background writes

    /// G3 hazard: the corpus keys on searchCorpusRevision, which every write to
    /// rawCalendarEvents bumps (colorDepth mirror flush, all-day range
    /// normalization, sync/domino writes all ride the SAME
    /// `didSet { … searchCorpusRevision &+= 1 }` seam). Here background writes
    /// (represented by in-band updateCalendarEvent commits — same seam) are
    /// interleaved with keystrokes. The build count must track the number of
    /// write-punctuated GROUPS, not the number of keystrokes: three keystrokes
    /// share one build within a group, and only a write forces the next
    /// group's single rebuild. If the cache degraded to per-keystroke rebuild
    /// (M4) this would be 9, not 3.
    func testCacheHitResilienceUnderInterleavedBackgroundWrites() {
        let (store, _) = makeEmptyStore("resilience")
        let anchor = seed(store, title: "Grocery planning", type: "Chores")

        func keystrokeGroup() {
            _ = store.calendarTypeSuggestion(rawText: "gro", availableTypes: ["Chores"])
            _ = store.calendarTypeSuggestion(rawText: "groc", availableTypes: ["Chores"])
            _ = store.calendarTypeSuggestion(rawText: "grocery", availableTypes: ["Chores"])
        }

        // Represents a background write between typing pauses. updateCalendarEvent
        // mutates rawCalendarEvents and bumps searchCorpusRevision — the exact
        // seam colorDepth-flush / all-day-normalization / sync writes use.
        func backgroundWrite(_ n: Int) {
            var mutated = store.findCalendarEvent(id: anchor.id)!
            mutated.note = "background touch \(n)"
            store.updateCalendarEvent(mutated)
        }

        keystrokeGroup()                       // group 1 → 1 build
        XCTAssertEqual(store.typeSuggestionCorpusBuildCount, 1)

        backgroundWrite(1)
        keystrokeGroup()                       // group 2 → 1 more build
        backgroundWrite(2)
        keystrokeGroup()                       // group 3 → 1 more build

        XCTAssertEqual(store.typeSuggestionCorpusBuildCount, 3,
                       "9 keystrokes across 3 write-punctuated groups must cost 3 builds, not 9 — no per-keystroke rebuild")
    }

    // MARK: - G5 verification hook

    /// The G5 line must carry BOTH required numbers beyond events/elapsedUs —
    /// cacheHit and an availableTypes generation — and the generation must be
    /// deterministic and order-sensitive (resolution returns the first
    /// normalize-equal title, so a reorder is a real resolution change).
    func testG5LineCarriesCacheHitAndOrderSensitiveGeneration() {
        let types = ["Study", "Work"]
        let line = CalendarTypeSuggestionDiagnostics.line(
            events: 2690, corpus: 2600, cacheHit: false, availableTypes: types, elapsedUs: 5123
        )
        XCTAssertTrue(line.contains("events=2690"), line)
        XCTAssertTrue(line.contains("cacheHit=false"), line)
        XCTAssertTrue(line.contains("elapsedUs=5123"), line)
        XCTAssertTrue(
            line.contains("availableTypesGen=\(CalendarTypeSuggestionDiagnostics.availableTypesGeneration(types))"),
            "the resolved-library generation is the second G5 number a stale-type miss shows up in: \(line)"
        )

        let gen = CalendarTypeSuggestionDiagnostics.availableTypesGeneration(types)
        XCTAssertEqual(gen, CalendarTypeSuggestionDiagnostics.availableTypesGeneration(["Study", "Work"]))
        XCTAssertNotEqual(gen, CalendarTypeSuggestionDiagnostics.availableTypesGeneration(["Work", "Study"]),
                          "order matters: first-match resolution makes a reorder a real change")
        XCTAssertNotEqual(gen, CalendarTypeSuggestionDiagnostics.availableTypesGeneration(["Study", "Work", "Exercise"]))
    }

    /// The hook is armed off the DiagnosticTrail sink and is silent by default.
    func testG5TrailSilentByDefaultAndWritesWhenArmed() {
        let (store, defaults) = makeEmptyStore("g5trail")
        DiagnosticTrail.clear()
        defer { DiagnosticTrail.clear() }
        seed(store, title: "Grocery planning", type: "Chores")

        _ = store.calendarTypeSuggestion(rawText: "grocery", availableTypes: ["Chores"])
        XCTAssertFalse(
            DiagnosticTrail.combinedText().contains(CalendarTypeSuggestionDiagnostics.trailCategory),
            "a disabled pass must write nothing"
        )

        defaults.set(true, forKey: CalendarTypeSuggestionDiagnostics.enabledDefaultsKey)
        _ = store.calendarTypeSuggestion(rawText: "grocery", availableTypes: ["Chores"])
        XCTAssertTrue(
            DiagnosticTrail.combinedText().contains(CalendarTypeSuggestionDiagnostics.trailCategory),
            "an armed pass must append one line to the trail"
        )
    }
}
