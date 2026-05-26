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
        let range = calendarOccurrenceDisplayRange(
            event: event,
            occurrenceDate: occurrenceDate,
            calendar: calendar
        ) ?? event.primaryTimeRange
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

    var id: UUID {
        event.id
    }

    var hasOccurrenceMatches: Bool {
        !occurrenceMatches.isEmpty
    }

    var primaryEventMatch: CalendarSearchTextMatch? {
        eventMatches.first
    }

    var defaultSelectionDate: Date {
        occurrenceMatches.first?.occurrenceDate ?? event.primaryTimeRange?.start ?? event.createdAt
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

        let occurrenceDate = defaultSelectionDate
        let range = calendarOccurrenceDisplayRange(
            event: event,
            occurrenceDate: occurrenceDate,
            calendar: calendar
        ) ?? event.primaryTimeRange
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

            return CalendarSearchResult(
                event: aggregation.event,
                eventMatches: eventMatches,
                occurrenceMatches: occurrenceMatches
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
    if lhs.hasOccurrenceMatches != rhs.hasOccurrenceMatches {
        return lhs.hasOccurrenceMatches && !rhs.hasOccurrenceMatches
    }

    let lhsDate = lhs.occurrenceMatches.first?.occurrenceDate ?? lhs.event.primaryTimeRange?.start ?? lhs.event.createdAt
    let rhsDate = rhs.occurrenceMatches.first?.occurrenceDate ?? rhs.event.primaryTimeRange?.start ?? rhs.event.createdAt
    if lhsDate != rhsDate {
        return lhsDate > rhsDate
    }

    return lhs.event.title.localizedCaseInsensitiveCompare(rhs.event.title) == .orderedAscending
}

struct CalendarSearchView: View {
    @EnvironmentObject private var store: EventStore
    @Environment(\.dismiss) private var dismiss

    @State private var query: String = ""
    @FocusState private var isSearchFocused: Bool

    var onOpenEvent: (CalendarEventOccurrenceContext) -> Void
    var onOpenOccurrenceLog: (CalendarEventOccurrenceContext) -> Void
    var onJumpToCalendar: (CalendarEventOccurrenceContext) -> Void

    private var filteredResults: [CalendarSearchResult] {
        // Deliberately raw `calendarEvents` (NOT canvasRenderable):
        // search should match absorbed todos by name — silently
        // filtering them would leave the user wondering why their
        // todo "doesn't exist" when they typed its title.
        // Future polish (deferred): annotate absorbed rows with
        // "inside: <parent title>" and route tap to parent detail
        // rather than a 404-style absent-canvas-block state.
        calendarSearchResults(
            query: query,
            events: store.calendarEvents,
            logRecords: store.calendarEventLogRecords,
            feedbackRecords: store.calendarEventFeedbackRecords
        )
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter
    }()

    var body: some View {
        ScrollView {
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView(
                    L(.searchEvents),
                    systemImage: "magnifyingglass",
                    description: Text(L(.searchHint))
                )
                .padding(.top, 60)
            } else if filteredResults.isEmpty {
                ContentUnavailableView.search(text: query)
                    .padding(.top, 60)
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(filteredResults) { result in
                        resultCard(result)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
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
        .onAppear {
            isSearchFocused = true
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
                    onOpenEvent(result.defaultContext())
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
                        onOpenEvent(result.defaultContext())
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
                onOpenOccurrenceLog(context)
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
                    onOpenOccurrenceLog(context)
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
            .accessibilityLabel("Jump to calendar")
        }
        .padding(.top, 2)
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
            occurrenceDate: result.defaultSelectionDate
        ) ?? result.event.primaryTimeRange
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
        return "\(Self.dateFormatter.string(from: range.start)) • \(calendarSearchTimeFormatter.string(from: range.start)) - \(calendarSearchTimeFormatter.string(from: range.end))"
    }
}

private var calendarSearchTimeFormatter: DateFormatter {
    let formatter = DateFormatter()
    if AppTimeFormat.current.is24 {
        formatter.dateFormat = "H:mm"
    } else {
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "h:mm a"
        formatter.amSymbol = "am"
        formatter.pmSymbol = "pm"
    }
    return formatter
}
