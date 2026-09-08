//
//  CalendarSearchHotPathTests.swift
//  DoneTests
//
//  gh#219 — the search keystroke hot path. Four proof obligations:
//
//    1. One body pass computes results ONCE, not twice. The old body
//       referenced `filteredResults` twice per pass (the `.isEmpty` check and
//       the `ForEach`), each running a full-corpus scan. `CalendarSearchEngine`
//       memoizes on (trimmed query, store revision), so two references in one
//       pass fold to one compute — probed via the engine's own `computeCount`.
//
//    2. Debounce: a burst of keystrokes runs ONE scan after typing settles.
//       The decision lives in the pure `CalendarSearchDebounce`, driven here
//       with injected `Date`s — no timers, no `Task.sleep`.
//
//    3. Cache EXACTNESS (RED LINE 3): same query + unchanged store ⇒ cached;
//       any store mutation under a FIXED query ⇒ recompute. The key includes
//       `EventStore.searchCorpusRevision`; a key that dropped `revision` would
//       serve the stale list at the mutation step and
//       `testCacheRecomputesWhenStoreMutatesUnderFixedQuery` would fail — the
//       "mutation kills the test" property the obligation asks for.
//
//    4. Parity: the cached/hoisted path returns the SAME results in the SAME
//       order as a direct `calendarSearchResults` scan, over a fixture with
//       events + logs + tags + diacritics.
//

import XCTest
@testable import Done

@MainActor
final class CalendarSearchHotPathTests: XCTestCase {

    // MARK: - Store harness (mirrors EventStoreLookupIndexTests, gh#213)

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var location: EventStorageLocation!

    override func setUp() {
        super.setUp()
        suiteName = "CalendarSearchHotPathTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        location = TestStorage.reset(suiteName)
    }

    override func tearDown() {
        TestStorage.tearDown(suiteName)
        defaults = nil
        suiteName = nil
        location = nil
        super.tearDown()
    }

    private func makeStore() -> EventStore {
        EventStore(defaults: defaults, storage: location, seedsSampleDataIfEmpty: false)
    }

    private let day = Date(timeIntervalSince1970: 1_770_000_000)

    private func event(
        _ title: String,
        id: UUID = UUID(),
        note: String = "",
        location: String = "",
        tags: [String] = [],
        type: String = "Study"
    ) -> Event {
        Event(
            id: id,
            title: title,
            note: note,
            location: location,
            timeRanges: [.init(start: day, end: day.addingTimeInterval(3600))],
            tags: tags,
            type: type
        )
    }

    private func logRecord(
        for event: Event,
        summary: String = "",
        note: String = ""
    ) -> CalendarEventLogRecord {
        CalendarEventLogRecord(
            id: CalendarOccurrenceKey.make(for: event, occurrenceDate: day),
            eventID: event.id,
            baseSeriesEventID: nil,
            occurrenceDate: day,
            summary: summary,
            note: note
        )
    }

    private func feedbackRecord(
        for event: Event,
        selfNote: String = "",
        timelineText: String? = nil
    ) -> CalendarEventFeedbackRecord {
        CalendarEventFeedbackRecord(
            id: CalendarOccurrenceKey.make(for: event, occurrenceDate: day),
            eventID: event.id,
            baseSeriesEventID: nil,
            occurrenceDate: day,
            selfNote: selfNote,
            logs: timelineText.map {
                [CalendarEventLogEntry(text: $0, source: "test")]
            } ?? []
        )
    }

    // MARK: - 1. Compute once per body pass

    /// The two references a single body pass makes to the result list — the
    /// empty-check and the `ForEach` — fold to ONE compute. Probed at the
    /// engine, which both references funnel through: two identical calls, one
    /// `computeCount` increment.
    func testTwoReferencesInOneBodyPassComputeOnce() {
        let store = makeStore()
        store.rawCalendarEvents = [event("Foobar")]
        let engine = CalendarSearchEngine()

        // Reference #1 — the `.isEmpty` gate.
        _ = engine.results(
            query: "foo",
            events: store.rawCalendarEvents,
            logRecords: store.calendarEventLogRecords,
            feedbackRecords: store.calendarEventFeedbackRecords,
            revision: store.searchCorpusRevision
        )
        // Reference #2 — the `ForEach`, same pass, same inputs.
        _ = engine.results(
            query: "foo",
            events: store.rawCalendarEvents,
            logRecords: store.calendarEventLogRecords,
            feedbackRecords: store.calendarEventFeedbackRecords,
            revision: store.searchCorpusRevision
        )

        XCTAssertEqual(engine.computeCount, 1,
                       "two references in one body pass must run the scan once, not twice")
    }

    // MARK: - 2. Debounce settles a burst into one scan

    func testDebounceBurstEmitsOnceAfterSettle() {
        var debounce = CalendarSearchDebounce(interval: 0.2)
        let t0 = Date(timeIntervalSince1970: 1000)

        // A three-keystroke burst, each within the window of the last.
        debounce.register(query: "a", now: t0)
        debounce.register(query: "ab", now: t0.addingTimeInterval(0.05))
        debounce.register(query: "abc", now: t0.addingTimeInterval(0.10))

        // The wake-ups scheduled by the first two keystrokes fire while a
        // later keystroke has already pushed the deadline out — no emission.
        XCTAssertNil(debounce.settledQuery(at: t0.addingTimeInterval(0.20)),
                     "the 'a' wake-up must not emit: 'abc' pushed the deadline to t0+0.30")
        XCTAssertNil(debounce.settledQuery(at: t0.addingTimeInterval(0.25)),
                     "the 'ab' wake-up must not emit either")
        XCTAssertNil(debounce.settledQuery(at: t0.addingTimeInterval(0.29)),
                     "still before the final deadline (t0+0.10 register + 0.2 interval = t0+0.30)")

        // The final keystroke's wake-up, past its deadline, emits exactly the
        // settled query — once. A real `Task.sleep(interval)` always wakes at
        // or after the deadline plus jitter, so `settledQuery` is probed here
        // at a time clearly past t0+0.30 rather than exactly on the boundary
        // (where Double rounding of 0.10+0.2 vs 0.30 is ambiguous).
        XCTAssertEqual(debounce.settledQuery(at: t0.addingTimeInterval(0.35)), "abc",
                       "one scan, of the final query, after the burst settles")
        XCTAssertNil(debounce.settledQuery(at: t0.addingTimeInterval(0.55)),
                     "a second wake-up after the emit finds nothing pending — exactly one scan")
    }

    /// `cancel()` (the instant-clear path) drops a pending keystroke so a
    /// stale wake-up can't re-apply just-cleared text.
    func testDebounceCancelDropsPendingKeystroke() {
        var debounce = CalendarSearchDebounce(interval: 0.2)
        let t0 = Date(timeIntervalSince1970: 2000)
        debounce.register(query: "abc", now: t0)
        debounce.cancel()
        XCTAssertNil(debounce.settledQuery(at: t0.addingTimeInterval(1.0)),
                     "a cancelled burst emits nothing, however late the wake-up")
    }

    // MARK: - 3. Cache exactness (RED LINE 3)

    /// Same query + unchanged store ⇒ cached; a store mutation under a FIXED
    /// query ⇒ recompute, with the recomputed value reflecting the mutation.
    ///
    /// This is the mutation-sensitive test the obligation names: the engine's
    /// key is (trimmed query, revision). Drop `revision` from that key and the
    /// third call below would hit the cache — `computeCount` would stay 1 and
    /// `after` would still be the stale non-empty list — so BOTH assertions in
    /// the mutation block would fail. The exact key is the only thing keeping
    /// them green.
    func testCacheRecomputesWhenStoreMutatesUnderFixedQuery() {
        let store = makeStore()
        store.rawCalendarEvents = [event("Foobar")]
        let engine = CalendarSearchEngine()
        let r0 = store.searchCorpusRevision

        let first = engine.results(
            query: "foo",
            events: store.rawCalendarEvents,
            logRecords: store.calendarEventLogRecords,
            feedbackRecords: store.calendarEventFeedbackRecords,
            revision: r0
        )
        XCTAssertEqual(engine.computeCount, 1)
        XCTAssertEqual(first.count, 1, "the fixture matches 'foo' before mutation")

        // Same query, store untouched — served from cache.
        _ = engine.results(
            query: "foo",
            events: store.rawCalendarEvents,
            logRecords: store.calendarEventLogRecords,
            feedbackRecords: store.calendarEventFeedbackRecords,
            revision: store.searchCorpusRevision
        )
        XCTAssertEqual(engine.computeCount, 1,
                       "unchanged store + identical query must be served from cache")

        // Mutate the corpus under the SAME query.
        store.rawCalendarEvents = []
        let r1 = store.searchCorpusRevision
        XCTAssertNotEqual(r1, r0, "a corpus mutation must bump searchCorpusRevision")

        let after = engine.results(
            query: "foo",
            events: store.rawCalendarEvents,
            logRecords: store.calendarEventLogRecords,
            feedbackRecords: store.calendarEventFeedbackRecords,
            revision: r1
        )
        XCTAssertEqual(engine.computeCount, 2,
                       "a store change under a fixed query MUST recompute — a key ignoring `revision` would serve the stale list and this would read 1")
        XCTAssertTrue(after.isEmpty,
                      "the recomputed list reflects the emptied store, not the cached non-empty result")
    }

    /// The store side of the exactness contract: every one of the three arrays
    /// the search reads bumps `searchCorpusRevision` when written, and an
    /// array the search does NOT read does not need to (and here does not).
    func testStoreRevisionBumpsOnEachSearchCorpusArrayWrite() {
        let store = makeStore()
        let anchor = event("Anchor")

        let r0 = store.searchCorpusRevision
        store.rawCalendarEvents = [anchor]
        let r1 = store.searchCorpusRevision
        XCTAssertGreaterThan(r1, r0, "rawCalendarEvents write must bump the revision")

        store.calendarEventLogRecords = [logRecord(for: anchor, summary: "s")]
        let r2 = store.searchCorpusRevision
        XCTAssertGreaterThan(r2, r1, "calendarEventLogRecords write must bump the revision")

        store.calendarEventFeedbackRecords = [feedbackRecord(for: anchor, selfNote: "n")]
        let r3 = store.searchCorpusRevision
        XCTAssertGreaterThan(r3, r2, "calendarEventFeedbackRecords write must bump the revision")
    }

    // MARK: - 4. Parity: cached path == direct scan

    /// A fixture that exercises event fields, tags, diacritics, log records,
    /// and feedback-derived timeline notes. The engine's result — value and
    /// order — must equal a direct `calendarSearchResults` scan.
    func testCachedPathMatchesDirectScan() {
        let cafe = event(
            "Morning Café",
            note: "Naïve plan",
            location: "Café Zürich",
            tags: ["Résumé", "work"],
            type: "Study"
        )
        let gym = event("Gym", type: "Fitness")
        let events = [cafe, gym]
        let logs = [
            logRecord(for: cafe, summary: "Café notes", note: "went well")
        ]
        let feedback = [
            feedbackRecord(for: gym, selfNote: "naive café attempt", timelineText: "timeline café note")
        ]

        // Diacritic- and case-insensitive: "cafe" matches "Café".
        let query = "cafe"
        let calendar = Calendar.current

        let direct = calendarSearchResults(
            query: query,
            events: events,
            logRecords: logs,
            feedbackRecords: feedback,
            calendar: calendar
        )
        let engine = CalendarSearchEngine()
        let viaEngine = engine.results(
            query: query,
            events: events,
            logRecords: logs,
            feedbackRecords: feedback,
            revision: 0,
            calendar: calendar
        )

        XCTAssertFalse(direct.isEmpty, "the fixture must actually match, or parity is vacuous")
        XCTAssertGreaterThanOrEqual(direct.count, 2, "both events should match on 'cafe'")
        XCTAssertEqual(viaEngine, direct,
                       "the memoized path must return identical results in identical order")

        // A cache hit returns the identical value too.
        let cached = engine.results(
            query: query,
            events: events,
            logRecords: logs,
            feedbackRecords: feedback,
            revision: 0,
            calendar: calendar
        )
        XCTAssertEqual(cached, direct)
        XCTAssertEqual(engine.computeCount, 1, "the second parity call is a cache hit")
    }

    /// Whitespace-only differences in the query trim to the same key, so they
    /// share the cache — the same behavior `calendarSearchResults` already has
    /// (it trims internally), now also reflected in the memo.
    func testTrimmedQueryVariantsShareCache() {
        let store = makeStore()
        store.rawCalendarEvents = [event("Foobar")]
        let engine = CalendarSearchEngine()
        let rev = store.searchCorpusRevision

        _ = engine.results(query: "foo", events: store.rawCalendarEvents,
                           logRecords: [], feedbackRecords: [], revision: rev)
        _ = engine.results(query: "  foo  ", events: store.rawCalendarEvents,
                           logRecords: [], feedbackRecords: [], revision: rev)
        XCTAssertEqual(engine.computeCount, 1,
                       "'foo' and '  foo  ' trim to the same key and share the cached scan")
    }
}
