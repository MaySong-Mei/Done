//
//  CategoryStatsBuilder.swift
//  Done
//

import Foundation

/// The Analysis tab's per-day accounting, up to the overlap sweep: which
/// occurrences count, under which category, over which intervals.
///
/// Shared by `AnalysisViewModel` (which sweeps the result into hours) and
/// `CategoryStatsBuilder` (which keeps the sweep's slices for the widget), so
/// the tab and the widget cannot disagree about a rule — there is one copy of
/// each.
nonisolated enum CategoryTimeAccounting {
    /// Index-aligned: `intervals[i]` is what counts toward `categories[i]`.
    struct Contributions {
        var categories: [String]
        var intervals: [[Event.TimeRange]]
        /// Each occurrence's own range, uncut: what the watch's "latest
        /// start" order reads (`WristForeground`).
        var ranges: [Event.TimeRange] = []
    }

    /// The bucket an event's time goes to: its type, "Other" when it has none.
    static func category(of event: Event) -> String {
        event.type.isEmpty ? "Other" : event.type
    }

    /// Each occurrence's time inside `[windowStart, windowEnd)`, with its
    /// embedded interrupt children cut out (the children count under their
    /// own type, so a parent/child pair never reads as an overlap).
    /// Occurrences with nothing left drop out.
    static func contributions(
        _ occurrences: [CalendarLayout.EventOccurrence], windowStart: Date, windowEnd: Date
    ) -> Contributions {
        let childRangesByParent = interruptChildRangesByParent(occurrences)
        var result = Contributions(categories: [], intervals: [])
        for occurrence in occurrences {
            let intervals = Event.remainingIntervals(
                occurrence.range,
                excluding: childRangesByParent[occurrence.event.id] ?? [],
                windowStart: windowStart,
                windowEnd: windowEnd
            )
            guard !intervals.isEmpty else { continue }
            result.categories.append(category(of: occurrence.event))
            result.intervals.append(intervals)
            result.ranges.append(occurrence.range)
        }
        return result
    }

    /// Maps each parent event ID to the ranges of its embedded interrupt
    /// children present in `occurrences`. Interrupt children render as their
    /// own occurrences (via `interruptRelation`), so they are collected once
    /// per day and subtracted from the matching parent.
    static func interruptChildRangesByParent(
        _ occurrences: [CalendarLayout.EventOccurrence]
    ) -> [UUID: [Event.TimeRange]] {
        var map: [UUID: [Event.TimeRange]] = [:]
        for occurrence in occurrences {
            guard let relation = occurrence.event.interruptRelation,
                  relation.state == .embedded else { continue }
            map[relation.parentEventID, default: []].append(occurrence.range)
        }
        return map
    }
}

/// Projection of the calendar into the category-stats widget's payload.
///
/// Runs the Analysis tab's own per-day pipeline — the same occurrences
/// (`CalendarLayout.occurrencesForDate` over the canvas-renderable events),
/// the same carving (`CategoryTimeAccounting`), the same sweep
/// (`Event.overlapSlices`) — over every day the widget's periods can reach,
/// and keeps the sweep's slices instead of reducing them to hours. Nothing is
/// clamped to the write time: the widget clamps at each entry's own instant
/// (`CategoryStats.hours`), which is what the tab's elapsed-clamp does at
/// that instant.
///
/// Pure: the caller supplies the clock, the calendar and the colours, as it
/// does for `WidgetSnapshotBuilder`.
nonisolated enum CategoryStatsBuilder {
    /// The days written: from the earliest start of any period that
    /// includes `now` — this week's, this month's, or the watch's last N
    /// days (`WristStatsPeriod`) — to the end of the
    /// occurrence snapshots' window, so the widget can keep answering for as
    /// long as it can keep showing events.
    static func coverage(now: Date, calendar: Calendar) -> (start: Date, end: Date) {
        let starts = [CategoryStatsPeriod.week, .month].map { CategoryStats.range(of: $0, containing: now, calendar: calendar).start }
            + WristStatsPeriod.allCases.map { $0.span(asOf: now, calendar: calendar).start }
        let end = WidgetSnapshotBuilder.window(now: now, calendar: calendar).end
        return (starts.min() ?? now, end)
    }

    /// The events as `payload` gets them off the main actor: the same
    /// values, with any detached instance's nominal day key filled in. A key
    /// missing at rest is resolved through the frozen reference zone
    /// (`Event.resolvedRecurrenceInstanceDayKey`), which is main-actor state;
    /// resolving it here, before the handoff, keeps the build itself clear of
    /// it. Every event minted through `Event.init` or the decoder already
    /// carries its key, so this is normally the array it was given.
    @MainActor
    static func handoff(_ events: [Event]) -> [Event] {
        guard events.contains(where: { $0.recurrenceInstanceDate != nil && $0.recurrenceInstanceDayKey == nil })
        else { return events }
        return events.map { event in
            guard event.recurrenceInstanceDayKey == nil, let date = event.recurrenceInstanceDate else { return event }
            var resolved = event
            resolved.recurrenceInstanceDayKey = Event.resolvedRecurrenceInstanceDayKey(dayKey: nil, legacyDate: date)
            return resolved
        }
    }

    /// Slices by category NAME; the indices are assigned once every name is
    /// known, in sorted order, so reordering the store's events cannot
    /// change the bytes (and spend a widget reload on nothing).
    private struct NamedSlice: Equatable {
        var start: Date
        var end: Date
        var n: Int
        var counts: [String: Int]
        /// `WristForeground.winner` of the covering occurrences; nil when
        /// one category covers the slice.
        var winner: String? = nil
    }

    /// Every day `previous` covers, by its start, with the slices it holds
    /// (none, for a day with nothing in it) — when `previous` can stand in
    /// for a build in `calendar`: this format, cut in the same calendar.
    ///
    /// A day's slices depend on that day's occurrences alone, and a running
    /// timer is drawn to the coverage's end, past every day either coverage
    /// holds; so a day built for one coverage is the same day built for
    /// another, and what makes `previous` reusable is only that it was built
    /// from the same events — which the caller has to know.
    private static func reusableDays(
        _ previous: CategoryStatsPayload?, calendar: Calendar
    ) -> [Date: [NamedSlice]] {
        guard let previous, let categories = previous.categories, let days = previous.days else { return [:] }
        var result: [Date: [NamedSlice]] = [:]
        for day in reusableDayStarts(previous, calendar: calendar) { result[day] = [] }
        guard !result.isEmpty else { return [:] }
        for day in days {
            guard let dayStart = day.start, result[dayStart] != nil else { continue }
            var slices: [NamedSlice] = []
            for slice in day.slices ?? [] {
                guard let start = slice.start, let end = slice.end, let n = slice.n else { return [:] }
                var counts: [String: Int] = [:]
                for (index, count) in zip(slice.categoryIndices ?? [], slice.counts ?? []) {
                    guard categories.indices.contains(index), let name = categories[index].name else { return [:] }
                    counts[name, default: 0] += count
                }
                // The winner leads the list (`CategoryStatsPayload.winners`).
                var winner: String?
                if counts.count > 1, let first = slice.categoryIndices?.first {
                    winner = categories[first].name
                }
                slices.append(NamedSlice(start: start, end: end, n: n, counts: counts, winner: winner))
            }
            result[dayStart] = slices
        }
        return result
    }

    /// The starts of the days `reusableDays` would take from `previous`,
    /// without reading their slices.
    private static func reusableDayStarts(_ previous: CategoryStatsPayload?, calendar: Calendar) -> Set<Date> {
        guard let previous, previous.version == CategoryStatsPayload.currentVersion,
              previous.calendar == CategoryStatsPayload.frame(of: calendar),
              let start = previous.coverageStart, let end = previous.coverageEnd,
              previous.categories != nil, previous.days != nil,
              // A payload from before the winners is rebuilt whole once, so
              // the watch's "latest start" rule has them everywhere.
              previous.winners == true
        else { return [] }
        return Set(CategoryStats.days(from: start, to: end, calendar: calendar).map { calendar.startOfDay(for: $0) })
    }

    /// How many days a build for `now` makes from the events, the rest
    /// coming from `previous` (`payload(...reusing:)`).
    static func daysToBuild(now: Date, calendar: Calendar, reusing previous: CategoryStatsPayload?) -> Int {
        let coverage = coverage(now: now, calendar: calendar)
        let reusable = reusableDayStarts(previous, calendar: calendar)
        let days = Set(CategoryStats.days(from: coverage.start, to: coverage.end, calendar: calendar)
            .map { calendar.startOfDay(for: $0) })
        return days.subtracting(reusable).count
    }

    /// `reusing`: a payload built from the same `events` in the same calendar
    /// at another instant. Its days are taken as they are and only the days
    /// it does not cover are built — the first sync of a new day builds one
    /// day. The result is the payload a build without it makes
    /// (`CategoryStatsEquivalenceTests.testAPayloadBuiltOnAnotherOnesDaysIsTheFullBuild`).
    static func payload(
        events: [Event],
        now: Date,
        calendar: Calendar,
        colorHex: (String) -> String?,
        reusing previous: CategoryStatsPayload? = nil
    ) -> CategoryStatsPayload {
        let coverage = coverage(now: now, calendar: calendar)
        let reusable = reusableDays(previous, calendar: calendar)

        var namedDays: [(start: Date, slices: [NamedSlice])] = []
        var seenDays: Set<Date> = []
        for day in CategoryStats.days(from: coverage.start, to: coverage.end, calendar: calendar) {
            let dayStart = calendar.startOfDay(for: day)
            guard seenDays.insert(dayStart).inserted,
                  let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { continue }
            if let known = reusable[dayStart] {
                if !known.isEmpty { namedDays.append((dayStart, known)) }
                continue
            }
            // A running timer's occurrence is drawn to the end of the
            // coverage: the widget cuts it at each entry's instant, which is
            // where the tab, reading the wall clock, would cut it then.
            let occurrences = CalendarLayout.occurrencesForDate(
                events, date: day, calendar: calendar, now: coverage.end
            )
            let contributions = CategoryTimeAccounting.contributions(
                occurrences, windowStart: dayStart, windowEnd: dayEnd
            )
            var slices: [NamedSlice] = []
            for slice in Event.overlapSlices(contributions: contributions.intervals) {
                var counts: [String: Int] = [:]
                for index in slice.covering { counts[contributions.categories[index], default: 0] += 1 }
                let winner = counts.count > 1
                    ? WristForeground.winner(slice.covering.map { index in
                        WristForeground.Candidate(
                            category: contributions.categories[index],
                            start: contributions.ranges[index].start, end: contributions.ranges[index].end
                        )
                    })
                    : nil
                let named = NamedSlice(
                    start: slice.start, end: slice.end, n: slice.covering.count, counts: counts, winner: winner
                )
                // Adjacent slices that credit the same shares, to the same
                // winner, are one slice: cut anywhere, the merged slice gives
                // what the two did.
                if let last = slices.last, last.end == named.start, last.n == named.n, last.counts == named.counts,
                   last.winner == named.winner {
                    slices[slices.count - 1].end = named.end
                } else {
                    slices.append(named)
                }
            }
            if !slices.isEmpty { namedDays.append((dayStart, slices)) }
        }

        let names = Set(namedDays.flatMap { $0.slices.flatMap { $0.counts.keys } }).sorted()
        let indexOf = Dictionary(uniqueKeysWithValues: names.enumerated().map { ($1, $0) })
        return CategoryStatsPayload(
            version: CategoryStatsPayload.currentVersion,
            writtenAt: now,
            coverageStart: coverage.start,
            coverageEnd: coverage.end,
            calendar: CategoryStatsPayload.frame(of: calendar),
            categories: names.map { CategoryStatsPayload.Category(name: $0, colorHex: colorHex($0)) },
            days: namedDays.map { day in
                CategoryStatsPayload.Day(start: day.start, slices: day.slices.map { slice in
                    // Index order, but the winner first: the watch reads it
                    // there (`CategoryStatsPayload.winners`).
                    let winner = slice.winner.flatMap { indexOf[$0] }
                    let ordered = slice.counts.keys.compactMap { indexOf[$0] }
                        .sorted { ($0 == winner ? -1 : $0) < ($1 == winner ? -1 : $1) }
                    return CategoryStatsPayload.Slice(
                        start: slice.start, end: slice.end, n: slice.n,
                        categoryIndices: ordered,
                        counts: ordered.map { slice.counts[names[$0]] ?? 0 }
                    )
                })
            },
            winners: true
        )
    }
}
