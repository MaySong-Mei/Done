//
//  CalendarSearchView.swift
//  Done
//

import SwiftUI

enum CalendarSearchMatchSource: String, Hashable, CaseIterable {
    case eventTitle
    case eventNote
    case eventLocation
    case eventTag
    case eventType
    case logSummary
    case logNote
    case timelineNote

    var title: String {
        switch self {
        case .eventTitle:
            return "Title"
        case .eventNote:
            return "Event Note"
        case .eventLocation:
            return "Location"
        case .eventTag:
            return "Tag"
        case .eventType:
            return "Type"
        case .logSummary:
            return "Log Summary"
        case .logNote:
            return "Log Note"
        case .timelineNote:
            return "Timeline Note"
        }
    }

    var priority: Int {
        switch self {
        case .timelineNote:
            return 0
        case .logNote:
            return 1
        case .logSummary:
            return 2
        case .eventNote:
            return 3
        case .eventTitle:
            return 4
        case .eventLocation:
            return 5
        case .eventTag:
            return 6
        case .eventType:
            return 7
        }
    }
}

struct CalendarSearchTextMatch: Hashable, Identifiable {
    let source: CalendarSearchMatchSource
    let snippet: String

    var id: String {
        "\(source.rawValue)-\(snippet)"
    }
}

struct CalendarSearchOccurrenceMatch: Hashable, Identifiable {
    let eventID: UUID
    let occurrenceDate: Date
    let isAllDay: Bool
    let snippets: [CalendarSearchTextMatch]

    var id: String {
        let day = Int(Calendar.current.startOfDay(for: occurrenceDate).timeIntervalSince1970)
        return "\(eventID.uuidString)-\(day)"
    }

    var sources: [CalendarSearchMatchSource] {
        snippets.map(\.source)
    }

    var primarySnippet: CalendarSearchTextMatch? {
        snippets.first
    }

    func context(for event: Event, calendar: Calendar = .current) -> CalendarEventOccurrenceContext {
        // Fallback in the render frame, not raw storage: it fires exactly
        // when the occurrence-day lookup misses — on a traveled detached
        // instance that is the common case, and the raw range would mint an
        // occurrenceID no canvas block carries (gh#187).
        let range = calendarOccurrenceDisplayRange(
            event: event,
            occurrenceDate: occurrenceDate,
            calendar: calendar
        ) ?? event.renderPrimaryTimeRange(calendar: calendar)
        let occurrenceID = range.map {
            calendarOccurrenceIDForRange(
                event: event,
                range: $0,
                occurrenceDate: occurrenceDate,
                calendar: calendar
            )
        }

        return CalendarEventOccurrenceContext(
            eventID: event.id,
            occurrenceDate: occurrenceDate,
            occurrenceID: occurrenceID,
            isAllDay: isAllDay,
            source: .timelineTap
        )
    }
}

struct CalendarSearchResult: Hashable, Identifiable {
    let event: Event
    let eventMatches: [CalendarSearchTextMatch]
    let occurrenceMatches: [CalendarSearchOccurrenceMatch]
    /// Start of the occurrence-resolved range the result card displays.
    /// Built once with the search calendar and used as the primary sort
    /// key: occurrence-day keys alone are startOfDay-normalized, which
    /// would invert time-of-day order against title-matched results
    /// keyed by full timestamps within the same day.
    let displayDate: Date

    var id: UUID {
        event.id
    }

    var primaryEventMatch: CalendarSearchTextMatch? {
        eventMatches.first
    }

    func defaultSelectionDate(calendar: Calendar = .current) -> Date {
        occurrenceMatches.first?.occurrenceDate
            ?? event.renderPrimaryTimeRange(calendar: calendar)?.start
            ?? event.createdAt
    }

    var previewOccurrenceMatches: [CalendarSearchOccurrenceMatch] {
        Array(occurrenceMatches.prefix(3))
    }

    var hiddenOccurrenceCount: Int {
        max(0, occurrenceMatches.count - previewOccurrenceMatches.count)
    }

    func defaultContext(calendar: Calendar = .current) -> CalendarEventOccurrenceContext {
        if let occurrenceMatch = occurrenceMatches.first {
            return occurrenceMatch.context(for: event, calendar: calendar)
        }

        let occurrenceDate = defaultSelectionDate(calendar: calendar)
        let range = calendarOccurrenceDisplayRange(
            event: event,
            occurrenceDate: occurrenceDate,
            calendar: calendar
        ) ?? event.renderPrimaryTimeRange(calendar: calendar)
        let occurrenceID = range.map {
            calendarOccurrenceIDForRange(
                event: event,
                range: $0,
                occurrenceDate: occurrenceDate,
                calendar: calendar
            )
        }

        return CalendarEventOccurrenceContext(
            eventID: event.id,
            occurrenceDate: occurrenceDate,
            occurrenceID: occurrenceID,
            isAllDay: event.isAllDay,
            source: .timelineTap
        )
    }
}

private struct CalendarSearchOccurrenceAggregation {
    let eventID: UUID
    let occurrenceDate: Date
    let isAllDay: Bool
    var snippetsBySource: [CalendarSearchMatchSource: String] = [:]

    mutating func addMatch(source: CalendarSearchMatchSource, snippet: String) {
        guard snippetsBySource[source] == nil else { return }
        snippetsBySource[source] = snippet
    }
}

private struct CalendarSearchAggregation {
    let event: Event
    var eventMatchesBySource: [CalendarSearchMatchSource: String] = [:]
    var occurrenceMatchesByDay: [Date: CalendarSearchOccurrenceAggregation] = [:]

    mutating func addEventMatch(source: CalendarSearchMatchSource, snippet: String) {
        guard eventMatchesBySource[source] == nil else { return }
        eventMatchesBySource[source] = snippet
    }

    mutating func addOccurrenceMatch(
        date: Date,
        isAllDay: Bool,
        source: CalendarSearchMatchSource,
        snippet: String,
        calendar: Calendar
    ) {
        let day = calendar.startOfDay(for: date)
        var match = occurrenceMatchesByDay[day] ?? CalendarSearchOccurrenceAggregation(
            eventID: event.id,
            occurrenceDate: day,
            isAllDay: isAllDay
        )
        match.addMatch(source: source, snippet: snippet)
        occurrenceMatchesByDay[day] = match
    }
}

func calendarSearchResults(
    query: String,
    events: [Event],
    logRecords: [CalendarEventLogRecord],
    feedbackRecords: [CalendarEventFeedbackRecord] = [],
    calendar: Calendar = .current
) -> [CalendarSearchResult] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }

    let eventByID = Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
    var aggregations: [UUID: CalendarSearchAggregation] = [:]

    func updateAggregation(for event: Event, _ update: (inout CalendarSearchAggregation) -> Void) {
        var aggregation = aggregations[event.id] ?? CalendarSearchAggregation(event: event)
        update(&aggregation)
        aggregations[event.id] = aggregation
    }

    func addEventMatch(event: Event, source: CalendarSearchMatchSource, text: String) {
        guard calendarSearchTextContains(text, query: trimmed) else { return }
        updateAggregation(for: event) { aggregation in
            aggregation.addEventMatch(
                source: source,
                snippet: calendarSearchSnippet(from: text)
            )
        }
    }

    func addOccurrenceMatch(
        event: Event,
        occurrenceDate: Date,
        source: CalendarSearchMatchSource,
        text: String
    ) {
        guard calendarSearchTextContains(text, query: trimmed) else { return }
        updateAggregation(for: event) { aggregation in
            aggregation.addOccurrenceMatch(
                date: occurrenceDate,
                isAllDay: event.isAllDay,
                source: source,
                snippet: calendarSearchSnippet(from: text),
                calendar: calendar
            )
        }
    }

    for event in events {
        addEventMatch(event: event, source: .eventTitle, text: event.title)
        addEventMatch(event: event, source: .eventNote, text: event.note)
        addEventMatch(event: event, source: .eventLocation, text: event.location)
        addEventMatch(event: event, source: .eventType, text: event.type)
        for tag in event.tags {
            addEventMatch(event: event, source: .eventTag, text: tag)
        }
    }

    for record in logRecords {
        guard let event = eventByID[record.eventID] else { continue }

        addOccurrenceMatch(
            event: event,
            occurrenceDate: record.occurrenceDate,
            source: .logSummary,
            text: record.summary
        )
        addOccurrenceMatch(
            event: event,
            occurrenceDate: record.occurrenceDate,
            source: .logNote,
            text: record.note
        )

        let timelineNotes = record.timelineItems
            .compactMap(\.noteValue)
            .sorted { $0.createdAt > $1.createdAt }

        for note in timelineNotes {
            addOccurrenceMatch(
                event: event,
                occurrenceDate: record.occurrenceDate,
                source: .timelineNote,
                text: note.text
            )
        }
    }

    for record in feedbackRecords {
        guard let event = eventByID[record.eventID] else { continue }

        addOccurrenceMatch(
            event: event,
            occurrenceDate: record.occurrenceDate,
            source: .logNote,
            text: record.selfNote
        )

        let logs = record.logs.sorted { $0.createdAt > $1.createdAt }
        for log in logs {
            addOccurrenceMatch(
                event: event,
                occurrenceDate: record.occurrenceDate,
                source: .timelineNote,
                text: log.text
            )
        }
    }

    return aggregations.values
        .map { aggregation in
            let eventMatches = aggregation.eventMatchesBySource
                .map { CalendarSearchTextMatch(source: $0.key, snippet: $0.value) }
                .sorted(by: calendarSearchMatchIsHigherPriority)

            let occurrenceMatches = aggregation.occurrenceMatchesByDay.values
                .map { occurrence in
                    let snippets = occurrence.snippetsBySource
                        .map { CalendarSearchTextMatch(source: $0.key, snippet: $0.value) }
                        .sorted(by: calendarSearchMatchIsHigherPriority)
                    return CalendarSearchOccurrenceMatch(
                        eventID: occurrence.eventID,
                        occurrenceDate: occurrence.occurrenceDate,
                        isAllDay: occurrence.isAllDay,
                        snippets: snippets
                    )
                }
                .sorted { lhs, rhs in
                    if lhs.occurrenceDate != rhs.occurrenceDate {
                        return lhs.occurrenceDate > rhs.occurrenceDate
                    }
                    return lhs.id < rhs.id
                }

            let event = aggregation.event
            // Render-frame fallbacks (gh#187): with no occurrence match the
            // selection/display seed is the event's own range, and for a
            // traveled detached instance the raw stored start names a day the
            // canvas draws nothing on.
            let selectionDate = occurrenceMatches.first?.occurrenceDate
                ?? event.renderPrimaryTimeRange(calendar: calendar)?.start
                ?? event.createdAt
            let displayDate = calendarOccurrenceDisplayRange(
                event: event,
                occurrenceDate: selectionDate,
                calendar: calendar
            )?.start
                ?? event.renderPrimaryTimeRange(calendar: calendar)?.start
                ?? event.createdAt

            return CalendarSearchResult(
                event: event,
                eventMatches: eventMatches,
                occurrenceMatches: occurrenceMatches,
                displayDate: displayDate
            )
        }
        .sorted(by: calendarSearchResultIsHigherPriority)
}

private func calendarSearchTextContains(_ text: String, query: String) -> Bool {
    guard !text.isEmpty else { return false }
    return text.range(
        of: query,
        options: [.caseInsensitive, .diacriticInsensitive]
    ) != nil
}

private func calendarSearchSnippet(from text: String, maxLength: Int = 88) -> String {
    let collapsed = text
        .split(whereSeparator: { $0.isWhitespace })
        .joined(separator: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)

    guard collapsed.count > maxLength else { return collapsed }
    return String(collapsed.prefix(maxLength - 3)) + "..."
}

private func calendarSearchMatchIsHigherPriority(
    _ lhs: CalendarSearchTextMatch,
    _ rhs: CalendarSearchTextMatch
) -> Bool {
    if lhs.source.priority != rhs.source.priority {
        return lhs.source.priority < rhs.source.priority
    }
    return lhs.snippet.localizedCaseInsensitiveCompare(rhs.snippet) == .orderedAscending
}

private func calendarSearchResultIsHigherPriority(
    _ lhs: CalendarSearchResult,
    _ rhs: CalendarSearchResult
) -> Bool {
    // Pure time order (newest first) — `displayDate` is the same
    // occurrence-resolved start the result card renders, so the visible
    // dates read monotonically down the list. Matching-source kind
    // (log vs title) deliberately does not partition the order.
    if lhs.displayDate != rhs.displayDate {
        return lhs.displayDate > rhs.displayDate
    }

    let titleOrder = lhs.event.title.localizedCaseInsensitiveCompare(rhs.event.title)
    if titleOrder != .orderedSame {
        return titleOrder == .orderedAscending
    }
    return lhs.event.id.uuidString < rhs.event.id.uuidString
}

/// Pure, timer-free debounce decision for the search field (gh#219). The
/// view drives it — `register` on each keystroke, `settledQuery` from a
/// wake-up `Task` — but the DECISION of whether the query has settled lives
/// here so it is testable with injected `Date`s instead of real sleeps
/// buried in the view. Each keystroke pushes the settle deadline out by
/// `interval`; a wake-up emits only once no newer keystroke has moved the
/// deadline past `now`, so a burst of N keystrokes yields exactly one
/// downstream scan.
struct CalendarSearchDebounce {
    let interval: TimeInterval
    private var pendingQuery: String?
    private var deadline: Date?

    init(interval: TimeInterval) {
        self.interval = interval
    }

    /// A keystroke arrived: record the latest query and reset the settle
    /// deadline to `now + interval`.
    mutating func register(query: String, now: Date) {
        pendingQuery = query
        deadline = now.addingTimeInterval(interval)
    }

    /// A wake-up fired at `now`. Emit the pending query exactly once iff its
    /// deadline has passed (no newer keystroke pushed it out); otherwise nil.
    /// Emitting clears the pending state, so a second wake-up at the same or
    /// later time returns nil — the "exactly one scan per burst" guarantee.
    mutating func settledQuery(at now: Date) -> String? {
        guard let deadline, let query = pendingQuery, now >= deadline else {
            return nil
        }
        self.deadline = nil
        self.pendingQuery = nil
        return query
    }

    /// Drop any pending keystroke without emitting — used when the field is
    /// cleared and the empty query is applied instantly, so a stale wake-up
    /// cannot later re-apply the just-cleared text.
    mutating func cancel() {
        pendingQuery = nil
        deadline = nil
    }
}

/// Memoizes `calendarSearchResults` across body passes (gh#219). That scan
/// builds a Dictionary of every event and runs diacritic-insensitive ICU
/// probes per field; the SwiftUI body referenced `filteredResults` twice per
/// pass and had no debounce, so a fast typist ran the full-corpus scan twice
/// per keystroke.
///
/// The cache key is (trimmed query, store corpus revision) and it is EXACT.
/// `calendarSearchResults` is a pure function of (query, events, logRecords,
/// feedbackRecords, calendar): it reads no `Date()`/now — its only date
/// sources are stored `occurrenceDate`/`createdAt` and the render-frame
/// projections `renderPrimaryTimeRange` / `calendarOccurrenceDisplayRange`,
/// each pure in its arguments — and `EventStore.searchCorpusRevision` bumps
/// on every write to any of those three arrays (gh#213 `didSet`s). So same
/// query + unchanged store ⇒ cached; any store mutation OR query change ⇒
/// recompute. `Calendar.current` is the one pure input left OUT of the key,
/// deliberately: a bare timezone change publishes nothing the search view
/// observes, so today's uncached `filteredResults` would not re-render on it
/// either — keying on (query, revision) reproduces today's behavior exactly
/// rather than diverging from it (RED LINE 4). Caching a value that MISSES a
/// real change would be a silent stale render (RED LINE 3); the revision
/// closes that by construction.
///
/// `computeCount` is a test probe scoped to the instance a test constructs;
/// production code never reads it.
final class CalendarSearchEngine {
    private struct Key: Equatable {
        let query: String
        let revision: Int
    }

    private var cachedKey: Key?
    private var cachedResults: [CalendarSearchResult] = []
    private(set) var computeCount = 0

    func results(
        query: String,
        events: [Event],
        logRecords: [CalendarEventLogRecord],
        feedbackRecords: [CalendarEventFeedbackRecord],
        revision: Int,
        calendar: Calendar = .current
    ) -> [CalendarSearchResult] {
        let key = Key(
            query: query.trimmingCharacters(in: .whitespacesAndNewlines),
            revision: revision
        )
        if cachedKey == key {
            return cachedResults
        }
        computeCount += 1
        let results = calendarSearchResults(
            query: query,
            events: events,
            logRecords: logRecords,
            feedbackRecords: feedbackRecords,
            calendar: calendar
        )
        cachedKey = key
        cachedResults = results
        return results
    }
}

struct CalendarSearchView: View {
    @EnvironmentObject private var store: EventStore
    @Environment(\.dismiss) private var dismiss

    /// Trailing debounce window: the corpus scan runs this long after the
    /// last keystroke (gh#219). The text field stays instant regardless.
    private static let debounceInterval: TimeInterval = 0.22

    @State private var query: String = ""
    /// The settled query that actually drives the corpus scan. The text
    /// field binds to `query` (instant); `debouncedQuery` trails it by
    /// `debounceInterval` after typing stops, so a burst of keystrokes runs
    /// one scan, not one per key.
    @State private var debouncedQuery: String = ""
    @State private var debounce = CalendarSearchDebounce(
        interval: CalendarSearchView.debounceInterval
    )
    /// Result-scan memo (gh#219). `@State` so the one instance persists
    /// across body passes; it is a plain reference, so SwiftUI never treats a
    /// cache write as a state change — the cache is a pure memo of the store,
    /// not observable UI state.
    @State private var searchEngine = CalendarSearchEngine()
    @FocusState private var isSearchFocused: Bool
    // Detail is pushed from HERE, not via CalendarPageView state: a
    // binding-based navigationDestination that is a sibling of the search
    // destination replaces the search entry in the stack, so popping the
    // detail landed back on the calendar instead of the results list.
    @State private var detailRoute: CalendarEventDetailRoute? = nil
    @State private var hasAutoFocusedSearchField = false

    var onJumpToCalendar: (CalendarEventOccurrenceContext) -> Void

    /// The result list for this body pass — driven by the debounced query
    /// and memoized on (query, store revision) by `searchEngine` (gh#219).
    ///
    /// Deliberately `rawCalendarEvents` (NOT canvasRenderable): search should
    /// match absorbed todos by name — silently filtering them would leave the
    /// user wondering why their todo "doesn't exist" when they typed its
    /// title. Future polish (deferred): annotate absorbed rows with
    /// "inside: <parent title>" and route tap to parent detail rather than a
    /// 404-style absent-canvas-block state.
    private func currentResults() -> [CalendarSearchResult] {
        searchEngine.results(
            query: debouncedQuery,
            events: store.rawCalendarEvents,
            logRecords: store.calendarEventLogRecords,
            feedbackRecords: store.calendarEventFeedbackRecords,
            revision: store.searchCorpusRevision
        )
    }

    /// Debounce driver (gh#219). The text field mutates `query` on every
    /// keystroke; this trails it into `debouncedQuery` once typing settles.
    private func applyQueryChange(_ newValue: String) {
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty query applies instantly — clearing the field should feel
        // immediate — and any pending keystroke is dropped so a late wake-up
        // cannot re-apply just-cleared text.
        if trimmed.isEmpty {
            debounce.cancel()
            debouncedQuery = newValue
            return
        }
        debounce.register(query: newValue, now: Date())
        // Wake after the interval and ask the pure model whether the query
        // settled. Earlier wake-ups return nil because a later keystroke
        // pushed the deadline out — that suppression IS the debounce, and it
        // lives in `settledQuery`, not in this Task. Both the `register`
        // above and the `settledQuery` below mutate the same `@State`
        // storage, so a stale wake-up reads the newest deadline.
        Task { @MainActor in
            try? await Task.sleep(
                nanoseconds: UInt64(Self.debounceInterval * 1_000_000_000)
            )
            if let settled = debounce.settledQuery(at: Date()) {
                debouncedQuery = settled
            }
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter
    }()

    var body: some View {
        // Compute the scan ONCE per body pass (gh#219): the empty-check and
        // the ForEach both read this single local, where they used to each
        // evaluate `filteredResults` and run a full-corpus scan (twice per
        // pass). `searchEngine` also memoizes across passes.
        let results = currentResults()
        return ScrollView {
            searchResultsContent(results)
        }
        .background(Color.clear)
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .top) {
            VStack(spacing: 8) {
                searchHeader
                searchField
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 8)
        }
        .navigationDestination(item: $detailRoute) { route in
            CalendarEventDetailView(route: route)
                .environmentObject(store)
        }
        .onChange(of: query) { _, newValue in
            applyQueryChange(newValue)
        }
        .onAppear {
            // First appear only — this also re-fires when the detail view
            // pops back to us, and re-focusing there would throw the keyboard
            // over the result the user just returned to. The focus write is
            // deferred a runloop turn: a synchronous write during the push
            // transition can be dropped while the field is not yet
            // focus-eligible, and the latch removes the retry the old
            // double-firing onAppear used to provide.
            guard !hasAutoFocusedSearchField else { return }
            hasAutoFocusedSearchField = true
            DispatchQueue.main.async {
                isSearchFocused = true
            }
        }
    }

    @ViewBuilder
    private func searchResultsContent(_ results: [CalendarSearchResult]) -> some View {
        // First branch gates on the LIVE `query` so the prompt hides the
        // instant the user starts typing; the list/empty state below reads
        // the passed-in `results`, which are keyed to the debounced query.
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ContentUnavailableView(
                L(.searchEvents),
                systemImage: "magnifyingglass",
                description: Text(L(.searchHint))
            )
            .padding(.top, 60)
        } else if results.isEmpty {
            ContentUnavailableView.search(text: query)
                .padding(.top, 60)
        } else {
            LazyVStack(spacing: 12) {
                ForEach(results) { result in
                    resultCard(result)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
    }

    private var searchHeader: some View {
        SwiftUI.GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    dismiss()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.left")
                            .font(.caption.weight(.semibold))
                        Text(L(.search))
                            .font(.system(size: 15, weight: .semibold))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 40)
                    .contentShape(Capsule())
                    .background(Color.black.opacity(0.001), in: Capsule())
                    .glassEffect(.regular.interactive(), in: Capsule())
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField(L(.searchPlaceholder), text: $query)
                .font(.subheadline)
                .focused($isSearchFocused)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .contentShape(Capsule())
        .background(Color.black.opacity(0.001), in: Capsule())
        .glassEffect(.regular.interactive(), in: Capsule())
    }

    @ViewBuilder
    private func resultCard(_ result: CalendarSearchResult) -> some View {
        GlassCardView(cornerRadius: 16, contentPadding: 14) {
            VStack(alignment: .leading, spacing: 12) {
                Button {
                    openEvent(result.defaultContext())
                } label: {
                    VStack(alignment: .leading, spacing: 10) {
                        eventSummary(result)
                        if let primaryEventMatch = result.primaryEventMatch,
                           shouldShowEventMatchSummary(for: result) {
                            matchSummaryLine(
                                title: primaryEventMatch.source.title,
                                text: primaryEventMatch.snippet
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button(L(.openEvent)) {
                        openEvent(result.defaultContext())
                    }
                    Button(L(.jumpToCalendar)) {
                        jumpToCalendar(result.defaultContext())
                    }
                }

                if !result.occurrenceMatches.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(result.previewOccurrenceMatches) { match in
                            occurrenceRow(match, event: result.event)
                        }
                        if result.hiddenOccurrenceCount > 0 {
                            Text("+\(result.hiddenOccurrenceCount) more matched occurrences")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func eventSummary(_ result: CalendarSearchResult) -> some View {
        let event = result.event

        VStack(alignment: .leading, spacing: 10) {
            Text(event.title)
                .font(.headline)

            HStack(alignment: .center, spacing: 8) {
                Circle()
                    .fill(CalendarLayout.eventColor(for: event))
                    .frame(width: 10, height: 10)
                Text(event.type.isEmpty ? "Calendar Event" : event.type)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            if let range = eventCardRange(for: result) {
                Label {
                    Text(timeDescription(range: range, event: event))
                } icon: {
                    Image(systemName: "clock")
                }
                .font(.subheadline)

                let minutes = Int(range.end.timeIntervalSince(range.start) / 60)
                let durationLabel = minutes >= 60
                    ? (minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h\(minutes % 60)m")
                    : "\(minutes)m"

                Label {
                    Text(durationLabel)
                } icon: {
                    Image(systemName: "hourglass")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

            if !event.location.isEmpty {
                Label {
                    Text(event.location)
                } icon: {
                    Image(systemName: "mappin")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func occurrenceRow(_ match: CalendarSearchOccurrenceMatch, event: Event) -> some View {
        let context = match.context(for: event)

        HStack(alignment: .top, spacing: 10) {
            Button {
                openOccurrenceLog(context)
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .center, spacing: 8) {
                        Text(occurrenceDescription(match, event: event))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                        Text(match.sources.map(\.title).joined(separator: " • "))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    if let primarySnippet = match.primarySnippet {
                        Text(primarySnippet.snippet)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button(L(.openLog)) {
                    openOccurrenceLog(context)
                }
                Button(L(.jumpToCalendar)) {
                    jumpToCalendar(context)
                }
            }

            Button {
                jumpToCalendar(context)
            } label: {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, height: 34)
                    .background(Color.secondary.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L(.jumpToCalendarA11y))
        }
        .padding(.top, 2)
    }

    private func openEvent(_ context: CalendarEventOccurrenceContext) {
        detailRoute = CalendarEventDetailRoute(occurrence: context)
    }

    private func openOccurrenceLog(_ context: CalendarEventOccurrenceContext) {
        detailRoute = CalendarEventDetailRoute(occurrence: context, initialJumpTarget: .log)
    }

    private func jumpToCalendar(_ context: CalendarEventOccurrenceContext) {
        onJumpToCalendar(context)
        dismiss()
    }

    private func shouldShowEventMatchSummary(for result: CalendarSearchResult) -> Bool {
        guard let primaryEventMatch = result.primaryEventMatch else { return false }
        return !(result.eventMatches.count == 1 && primaryEventMatch.source == .eventTitle)
    }

    private func eventCardRange(for result: CalendarSearchResult) -> Event.TimeRange? {
        calendarOccurrenceDisplayRange(
            event: result.event,
            occurrenceDate: result.defaultSelectionDate()
        ) ?? result.event.renderPrimaryTimeRange(calendar: .current)
    }

    private func occurrenceDescription(_ match: CalendarSearchOccurrenceMatch, event: Event) -> String {
        if let range = calendarOccurrenceDisplayRange(
            event: event,
            occurrenceDate: match.occurrenceDate
        ) {
            return calendarOccurrenceTimeSummary(event: event, range: range)
        }

        return Self.dateFormatter.string(from: match.occurrenceDate)
    }

    @ViewBuilder
    private func matchSummaryLine(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
    }

    private func timeDescription(range: Event.TimeRange, event: Event) -> String {
        if event.isAllDay {
            return "\(Self.dateFormatter.string(from: range.start)) • All-day"
        }
        let timeFormatter = CalendarSearchTimeFormatter.current
        return "\(Self.dateFormatter.string(from: range.start)) • \(timeFormatter.string(from: range.start)) - \(timeFormatter.string(from: range.end))"
    }
}

/// Pre-built time formatters for search result rows (gh#219). The old
/// `calendarSearchTimeFormatter` was a computed `var` that CONSTRUCTED a
/// `DateFormatter` on every access — once per rendered result row, and a
/// `DateFormatter` is expensive to build and cheap to reuse. The two shapes
/// are built once here; `current` selects between them by the live 24h/12h
/// setting, re-read on each call so a settings change is honored exactly as
/// the old computed var did. Output is identical to the old code for a fixed
/// device locale: the 12h shape pins `en_US_POSIX` and its am/pm symbols
/// exactly as before, and the 24h shape sets no locale so it inherits the
/// device locale just as the freshly-constructed formatter did — the only
/// difference is that inheritance is captured at first access rather than
/// per call, which matters only across a mid-session locale change (the same
/// property any `static let DateFormatter` in this app carries — e.g.
/// `TimelineView.boundaryDayHintWeekdayFormatter`). Format strings are
/// byte-for-byte the old ones; only the construction is amortized (mirrors
/// the render lane's static formatters).
private enum CalendarSearchTimeFormatter {
    static let twentyFourHour: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "H:mm"
        return formatter
    }()

    static let twelveHour: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "h:mm a"
        formatter.amSymbol = "am"
        formatter.pmSymbol = "pm"
        return formatter
    }()

    static var current: DateFormatter {
        AppTimeFormat.current.is24 ? twentyFourHour : twelveHour
    }
}
