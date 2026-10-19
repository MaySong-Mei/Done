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
enum CategoryTimeAccounting {
    /// Index-aligned: `intervals[i]` is what counts toward `categories[i]`.
    struct Contributions {
        var categories: [String]
        var intervals: [[Event.TimeRange]]
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
enum CategoryStatsBuilder {
    /// The days written: from the earlier of this week's and this month's
    /// start — the furthest back any period that includes `now` reaches —
    /// to the end of the occurrence snapshots' window, so the widget can keep
    /// answering for as long as it can keep showing events.
    static func coverage(now: Date, calendar: Calendar) -> (start: Date, end: Date) {
        let week = CategoryStats.range(of: .week, containing: now, calendar: calendar)
        let month = CategoryStats.range(of: .month, containing: now, calendar: calendar)
        let end = WidgetSnapshotBuilder.window(now: now, calendar: calendar).end
        return (min(week.start, month.start), end)
    }

    static func payload(
        events: [Event],
        now: Date,
        calendar: Calendar,
        colorHex: (String) -> String?
    ) -> CategoryStatsPayload {
        let coverage = coverage(now: now, calendar: calendar)

        // Slices by category NAME first; the indices are assigned once every
        // name is known, in sorted order, so reordering the store's events
        // cannot change the bytes (and spend a widget reload on nothing).
        struct NamedSlice {
            var start: Date
            var end: Date
            var n: Int
            var counts: [String: Int]
        }
        var namedDays: [(start: Date, slices: [NamedSlice])] = []
        var seenDays: Set<Date> = []
        for day in CategoryStats.days(from: coverage.start, to: coverage.end, calendar: calendar) {
            let dayStart = calendar.startOfDay(for: day)
            guard seenDays.insert(dayStart).inserted,
                  let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { continue }
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
                let named = NamedSlice(start: slice.start, end: slice.end, n: slice.covering.count, counts: counts)
                // Adjacent slices that credit the same shares are one slice:
                // cut anywhere, the merged slice gives what the two did.
                if let last = slices.last, last.end == named.start, last.n == named.n, last.counts == named.counts {
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
                    let ordered = slice.counts.keys.compactMap { indexOf[$0] }.sorted()
                    return CategoryStatsPayload.Slice(
                        start: slice.start, end: slice.end, n: slice.n,
                        categoryIndices: ordered,
                        counts: ordered.map { slice.counts[names[$0]] ?? 0 }
                    )
                })
            }
        )
    }
}
