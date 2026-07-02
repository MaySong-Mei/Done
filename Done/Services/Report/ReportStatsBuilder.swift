//
//  ReportStatsBuilder.swift
//  Done
//
//  Pure statistics layer for the generative report system (Discussion #111).
//
//  Turns a flat array of `Event`s into a `ReportStats` payload.  The whole
//  computation is a pure function of its inputs:
//
//    * No `Date()` / "now" anywhere on the calculation path — the window is
//      fully described by `start`/`end`, and occurrences are expanded from the
//      events' own `timeRanges` (a live `timerStartedAt` range is deliberately
//      ignored; it isn't a committed record yet and reading it would mean
//      touching the wall-clock).
//    * No `EventStore` / `@MainActor` / global mutable state — inputs are value
//      types, output is a value type, so `build` can run on a background thread.
//
//  Dataset contract: the caller is expected to pass the SAME set the Analysis
//  charts feed on — `EventStore.canvasRenderableCalendarEvents` (raw calendar
//  events minus absorbed todos).  A report and a chart shown on the same screen
//  must never disagree, so the SET must match; feeding raw events would
//  double-count an absorbed todo against its parent's window.  `build` itself
//  does not know about the store — enforcing the right set is the call site's
//  job (mirroring `AnalysisViewModel.typeAllocations`).
//
//  `events` may contain occurrences outside the window (the caller filters
//  coarsely); `build` filters precisely to `[start, end)` and reuses the same
//  array to compute the previous equal-length window `[start - length, start)`
//  as a comparison baseline.
//

import Foundation

enum ReportStatsBuilder {

    // A single expanded occurrence — one event's time range on the timeline.
    // Recurring series are expanded into these per matching day; single events
    // contribute their committed `timeRanges`.  Mirrors
    // `CalendarLayout.EventOccurrence` but built here without the timer/`Date()`
    // branch so the computation stays wall-clock-free.
    private struct Occurrence {
        let event: Event
        let range: Event.TimeRange
    }

    // MARK: - Entry point

    static func build(
        events: [Event],
        start: Date,
        end: Date,
        calendar: Calendar
    ) -> ReportStats {
        let length = end.timeIntervalSince(start)
        let previousStart = start.addingTimeInterval(-length)

        // Expand once over the union of both windows, then slice per window.
        let allOccurrences = expandOccurrences(
            events: events,
            windowStart: previousStart,
            windowEnd: end,
            calendar: calendar
        )
        let currentOccurrences = allOccurrences.filter {
            $0.range.end > start && $0.range.start < end
        }
        let previousOccurrences = allOccurrences.filter {
            $0.range.end > previousStart && $0.range.start < start
        }

        let days = calendarDays(from: start, to: end, calendar: calendar)

        // --- Window metadata --------------------------------------------------
        let recordedDays = days.filter { day in
            currentOccurrences.contains { occ in
                occ.range.end > calendar.startOfDay(for: day)
                    && occ.range.start < dayEnd(day, calendar)
            }
        }
        let eventIDs = Set(currentOccurrences.map { $0.event.id })
        let meta = ReportWindowMeta(
            start: start,
            end: end,
            dayCount: days.count,
            recordedDayCount: recordedDays.count,
            eventCount: eventIDs.count,
            isThin: recordedDays.count < ReportTuning.thinMinRecordedDays
                || eventIDs.count < ReportTuning.thinMinEvents
        )

        // --- perTypeHours (split-at-midnight, weight-distributed) ------------
        let currentTypeHours = weightedTypeHours(
            occurrences: currentOccurrences, days: days, calendar: calendar
        )
        let previousDays = calendarDays(from: previousStart, to: start, calendar: calendar)
        let previousTypeHours = weightedTypeHours(
            occurrences: previousOccurrences, days: previousDays, calendar: calendar
        )
        let perTypeHours = makeTypeHours(
            current: currentTypeHours,
            previous: previousTypeHours,
            isThin: meta.isThin
        )

        // --- dailyTotals (split-at-midnight, matches the chart) --------------
        let dailyTotals = days.map { day in
            ReportDailyTotal(
                date: day,
                hours: netClampedTotalHours(occurrences: currentOccurrences, on: day, calendar: calendar)
            )
        }

        // --- sessionDaily (whole-occurrence attribution, cross-midnight fixed)
        let sessionDaily = weightedSessionDaily(
            occurrences: currentOccurrences, calendar: calendar
        )

        // --- typePairRelations (top-N by total hours) ------------------------
        let typePairRelations = makePairRelations(
            perTypeHours: perTypeHours,
            sessionDaily: sessionDaily,
            recordedDays: recordedDays
        )

        // --- timeOfDayShares --------------------------------------------------
        let timeOfDayShares = makeTimeOfDayShares(
            occurrences: currentOccurrences, calendar: calendar
        )

        return ReportStats(
            window: meta,
            perTypeHours: perTypeHours,
            dailyTotals: dailyTotals,
            sessionDaily: sessionDaily,
            typePairRelations: typePairRelations,
            timeOfDayShares: timeOfDayShares
        )
    }

    // MARK: - Event detail serialization

    /// Serializes the window's individual records for the prompt's EVENTS
    /// block — the texture (titles, notes) that lets the report reference
    /// specific moments instead of speaking only in category totals.  Numbers
    /// remain the DATA block's job; this block is quotable specifics.
    ///
    /// Chronological, one line per occurrence:
    /// `EVENT Mon 2026-06-29 09:00–12:00 [type] title — note`.  Notes are
    /// flattened to one line and clipped to `ReportTuning.maxNoteChars`.
    /// All-day events are excluded, consistent with the report's accounting
    /// everywhere else.  When the budget runs out the tail is dropped and a
    /// final line states how many records were omitted — never silently.
    static func promptEvents(
        events: [Event],
        start: Date,
        end: Date,
        calendar: Calendar,
        budget: Int
    ) -> String {
        guard budget > 0 else { return "" }
        let occurrences = expandOccurrences(
            events: events, windowStart: start, windowEnd: end, calendar: calendar
        )
        .filter { $0.range.end > start && $0.range.start < end }
        .sorted { $0.range.start < $1.range.start }
        guard !occurrences.isEmpty else { return "" }

        // Model-facing formatting: fixed POSIX locale so the block is stable
        // regardless of device locale; the passed calendar keeps day/time
        // boundaries consistent with the DATA block.
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.calendar = calendar
        dayFormatter.timeZone = calendar.timeZone
        dayFormatter.dateFormat = "EEE yyyy-MM-dd"
        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.calendar = calendar
        timeFormatter.timeZone = calendar.timeZone
        timeFormatter.dateFormat = "HH:mm"

        // A recurring series would repeat an identical title/note once per day
        // and crowd the budget with low-information lines, pushing the unique
        // records this block exists for into the omitted tail — so each series
        // collapses to one line carrying its in-window count.
        var entries: [String] = []
        var seriesSeen: Set<UUID> = []
        func makeLine(_ occ: Occurrence, recurringCount: Int?) -> String {
            var line = "EVENT \(dayFormatter.string(from: occ.range.start)) "
                + "\(timeFormatter.string(from: occ.range.start))–\(timeFormatter.string(from: occ.range.end)) "
                + "[\(occ.event.type.isEmpty ? "Other" : occ.event.type)] \(occ.event.title)"
            if let recurringCount, recurringCount > 1 {
                line += " (recurring, ×\(recurringCount) this period)"
            }
            // `\R` covers \n, \r\n, \r, and the Unicode line/paragraph
            // separators — anything that would break the one-line contract.
            let note = occ.event.note
                .replacingOccurrences(of: "\\R", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !note.isEmpty {
                line += " — \(note.prefix(ReportTuning.maxNoteChars))"
            }
            return line
        }
        for occ in occurrences {
            if occ.event.isRecurringSeries {
                guard seriesSeen.insert(occ.event.id).inserted else { continue }
                let count = occurrences.filter { $0.event.id == occ.event.id }.count
                entries.append(makeLine(occ, recurringCount: count))
            } else {
                entries.append(makeLine(occ, recurringCount: nil))
            }
        }

        let budgetChars = budget * ReportTuning.charsPerToken
        var lines: [String] = []
        var usedChars = 0
        for entry in entries {
            guard usedChars + entry.count + 1 <= budgetChars else { break }
            lines.append(entry)
            usedChars += entry.count + 1
        }
        let omitted = entries.count - lines.count
        if omitted > 0 {
            lines.append("(+\(omitted) more records omitted for length)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Occurrence expansion

    // Expands events into occurrences overlapping `[windowStart, windowEnd)`.
    // All-day events are skipped (they carry no time-of-day duration), and the
    // live-timer range is ignored — see the file header for why.
    private static func expandOccurrences(
        events: [Event],
        windowStart: Date,
        windowEnd: Date,
        calendar: Calendar
    ) -> [Occurrence] {
        var result: [Occurrence] = []
        for event in events {
            if event.isAllDay { continue }

            if event.isRecurringSeries {
                // Walk each day in the union window and ask the shared
                // recurrence helper (which is itself wall-clock-free).
                var day = calendar.startOfDay(for: windowStart)
                let lastDay = calendar.startOfDay(for: windowEnd)
                while day <= lastDay {
                    if let range = CalendarLayout.recurrenceOccurrence(for: event, on: day, calendar: calendar),
                       range.end > windowStart, range.start < windowEnd {
                        result.append(Occurrence(event: event, range: range))
                    }
                    guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                    day = next
                }
                continue
            }

            for range in event.timeRanges where range.end > windowStart && range.start < windowEnd {
                result.append(Occurrence(event: event, range: range))
            }
        }
        return result
    }

    // MARK: - Interrupt netting (parity with AnalysisViewModel)

    // Ranges of embedded interrupt children keyed by their parent event id.
    // Interrupt children surface as their own occurrences (under their own
    // type), so their time is subtracted from the parent to keep total
    // wall-clock conserved — same decision as `AnalysisViewModel`.
    private static func interruptChildRanges(
        _ occurrences: [Occurrence]
    ) -> [UUID: [Event.TimeRange]] {
        var map: [UUID: [Event.TimeRange]] = [:]
        for occ in occurrences {
            guard let relation = occ.event.interruptRelation,
                  relation.state == .embedded else { continue }
            map[relation.parentEventID, default: []].append(occ.range)
        }
        return map
    }

    // Net hours an occurrence held on `day` after clamping to the day and
    // subtracting its embedded interrupt children (overlaps merged once).
    private static func netClampedHours(
        _ occurrence: Occurrence,
        childRanges: [Event.TimeRange],
        on day: Date,
        calendar: Calendar
    ) -> Double {
        let dayStart = calendar.startOfDay(for: day)
        let dayEndDate = dayEnd(day, calendar)
        func clampToDay(_ range: Event.TimeRange) -> Event.TimeRange? {
            let s = max(range.start, dayStart)
            let e = min(range.end, dayEndDate)
            return e > s ? Event.TimeRange(start: s, end: e) : nil
        }
        guard let dayParent = clampToDay(occurrence.range) else { return 0 }
        guard !childRanges.isEmpty else {
            return max(0, dayParent.end.timeIntervalSince(dayParent.start)) / 3600
        }
        let dayChildren = childRanges.compactMap(clampToDay)
        return Event.interruptedDuration(parentRange: dayParent, childRanges: dayChildren).netSeconds / 3600
    }

    // Whole-occurrence net hours (not clamped to any day) after subtracting
    // embedded interrupt children — used by the session (whole-attribution)
    // aggregation.
    private static func netWholeHours(
        _ occurrence: Occurrence,
        childRanges: [Event.TimeRange]
    ) -> Double {
        Event.interruptedDuration(
            parentRange: occurrence.range,
            childRanges: childRanges
        ).netSeconds / 3600
    }

    // MARK: - Type-weight distribution

    // Normalized (type, weight) pairs summing to 1 for one event, applying the
    // documented `effectiveTypeWeights` semantics: `typeWeights == nil` splits
    // equally across `effectiveTypes`; otherwise each type takes its listed
    // weight (clamped to ≥ 0), a type missing from the dict falls back to the
    // mean of the provided weights, and the result is renormalized.  (The
    // canonical `Event.effectiveTypeWeights` helper is referenced in comments
    // on `Event` but not yet implemented, so the semantics live here for now.)
    //
    // Empty type strings collapse to the same "Other" bucket the Analysis chart
    // uses, so single-category numbers line up with `typeAllocations`.
    private static func normalizedTypeWeights(for event: Event) -> [(type: String, weight: Double)] {
        let types = event.effectiveTypes.map { $0.isEmpty ? "Other" : $0 }
        guard types.count > 1 else {
            return [(types.first ?? "Other", 1.0)]
        }
        guard let weights = event.typeWeights, !weights.isEmpty else {
            let equal = 1.0 / Double(types.count)
            return types.map { ($0, equal) }
        }
        let provided = event.effectiveTypes.compactMap { weights[$0] }.filter { $0 >= 0 }
        let fallback = provided.isEmpty ? 1.0 : provided.reduce(0, +) / Double(provided.count)
        let raw = event.effectiveTypes.map { max(0, weights[$0] ?? fallback) }
        let sum = raw.reduce(0, +)
        guard sum > 0 else {
            let equal = 1.0 / Double(types.count)
            return types.map { ($0, equal) }
        }
        return zip(types, raw).map { ($0, $1 / sum) }
    }

    // MARK: - Aggregations

    // Per-type total hours over `days`, split at midnight and distributed across
    // an event's types by weight.  This is the report's counterpart to the
    // chart's `typeAllocations`; it diverges only for multi-type events (the
    // experimental feature), where the chart still counts primary-type-only.
    private static func weightedTypeHours(
        occurrences: [Occurrence],
        days: [Date],
        calendar: Calendar
    ) -> [String: Double] {
        var hoursByType: [String: Double] = [:]
        let childRanges = interruptChildRanges(occurrences)
        for day in days {
            for occ in occurrences {
                let net = netClampedHours(
                    occ,
                    childRanges: childRanges[occ.event.id] ?? [],
                    on: day,
                    calendar: calendar
                )
                guard net > 0 else { continue }
                for (type, weight) in normalizedTypeWeights(for: occ.event) {
                    hoursByType[type, default: 0] += net * weight
                }
            }
        }
        return hoursByType
    }

    // Day's total scheduled hours (all types), split at midnight — the value
    // `dailyTotals` and `AnalysisViewModel.totalScheduledHours` agree on.
    private static func netClampedTotalHours(
        occurrences: [Occurrence],
        on day: Date,
        calendar: Calendar
    ) -> Double {
        let childRanges = interruptChildRanges(occurrences)
        return occurrences.reduce(0.0) { acc, occ in
            acc + netClampedHours(
                occ,
                childRanges: childRanges[occ.event.id] ?? [],
                on: day,
                calendar: calendar
            )
        }
    }

    // Whole-occurrence per-type per-day hours: an occurrence lands entirely on
    // the day it overlaps more (ties go to the end day), so a cross-midnight
    // session isn't torn into a fake two-day pattern before the relationship
    // math sees it.
    private static func weightedSessionDaily(
        occurrences: [Occurrence],
        calendar: Calendar
    ) -> [ReportTypeDayHours] {
        let childRanges = interruptChildRanges(occurrences)
        var byKey: [String: Double] = [:]     // "type|dayEpoch" → hours
        var dayByEpoch: [TimeInterval: Date] = [:]
        for occ in occurrences {
            let net = netWholeHours(occ, childRanges: childRanges[occ.event.id] ?? [])
            guard net > 0 else { continue }
            let day = dominantDay(for: occ.range, calendar: calendar)
            let epoch = day.timeIntervalSince1970
            dayByEpoch[epoch] = day
            for (type, weight) in normalizedTypeWeights(for: occ.event) {
                byKey["\(type)|\(epoch)", default: 0] += net * weight
            }
        }
        return byKey.compactMap { key, hours in
            let parts = key.split(separator: "|", maxSplits: 1)
            guard parts.count == 2, let epoch = TimeInterval(parts[1]), let day = dayByEpoch[epoch] else {
                return nil
            }
            return ReportTypeDayHours(type: String(parts[0]), date: day, hours: hours)
        }
        .sorted { $0.date == $1.date ? $0.type < $1.type : $0.date < $1.date }
    }

    // Day (start-of-day) an occurrence overlaps most; ties resolve to the later
    // day.  A 23:00→07:00 session overlaps 1h on day 1 and 7h on day 2 → day 2.
    private static func dominantDay(for range: Event.TimeRange, calendar: Calendar) -> Date {
        var day = calendar.startOfDay(for: range.start)
        let lastDay = calendar.startOfDay(for: range.end)
        var bestDay = day
        var bestOverlap = -1.0
        while day <= lastDay {
            let dStart = day
            let dEnd = dayEnd(day, calendar)
            let overlap = max(0, min(range.end, dEnd).timeIntervalSince(max(range.start, dStart)))
            // `>=` so a tie prefers the later day (loop advances forward).
            if overlap >= bestOverlap {
                bestOverlap = overlap
                bestDay = day
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return bestDay
    }

    // MARK: - Pair relations

    // Correlations run over the window's *recorded* days only.  Days with no
    // record at all would enter every vector as (0, 0) and drag every pair
    // toward a spurious positive r (co-absence measures "did the user track
    // that day", not how two categories move together).  A recorded day where
    // one category is absent stays in — that's genuine signal about the pair.
    private static func makePairRelations(
        perTypeHours: [ReportTypeHours],
        sessionDaily: [ReportTypeDayHours],
        recordedDays: [Date]
    ) -> [ReportTypePairRelation] {
        let topTypes = perTypeHours
            .sorted { $0.hours > $1.hours }
            .prefix(ReportTuning.maxPairTypes)
            .map { $0.type }
        guard topTypes.count >= 2 else { return [] }

        // Dense per-type daily vectors aligned to `recordedDays`.
        let dayIndex: [TimeInterval: Int] = Dictionary(
            uniqueKeysWithValues: recordedDays.enumerated().map { ($0.element.timeIntervalSince1970, $0.offset) }
        )
        var vectors: [String: [Double]] = [:]
        for type in topTypes { vectors[type] = Array(repeating: 0, count: recordedDays.count) }
        for entry in sessionDaily where vectors[entry.type] != nil {
            if let idx = dayIndex[entry.date.timeIntervalSince1970] {
                vectors[entry.type]?[idx] += entry.hours
            }
        }

        var relations: [ReportTypePairRelation] = []
        for i in 0..<topTypes.count {
            for j in (i + 1)..<topTypes.count {
                let a = topTypes[i], b = topTypes[j]
                guard let va = vectors[a], let vb = vectors[b] else { continue }
                let r = pearson(va, vb)
                let overlapDays = zip(va, vb).filter { $0 > 0 && $1 > 0 }.count
                let consistency = signConsistency(va, vb)
                let confidence = ReportConfidenceInput(
                    overlapDays: overlapDays,
                    consistency: consistency,
                    effectSize: abs(r)
                )
                relations.append(ReportTypePairRelation(
                    typeA: a, typeB: b, correlation: r, confidence: confidence
                ))
            }
        }
        return relations.sorted { $0.confidence.effectSize > $1.confidence.effectSize }
    }

    // Cross-half-window sign agreement: split the vectors in two, take the
    // Pearson sign in each half; 1 when both halves point the same non-zero
    // direction, else 0.  Guards against a correlation that flips mid-window.
    private static func signConsistency(_ x: [Double], _ y: [Double]) -> Double {
        guard x.count >= 4 else { return 0 }
        let mid = x.count / 2
        let firstSign = pearson(Array(x[..<mid]), Array(y[..<mid])).sign01
        let secondSign = pearson(Array(x[mid...]), Array(y[mid...])).sign01
        return (firstSign != 0 && firstSign == secondSign) ? 1 : 0
    }

    private static func pearson(_ x: [Double], _ y: [Double]) -> Double {
        guard x.count == y.count, x.count >= 2 else { return 0 }
        let n = Double(x.count)
        let meanX = x.reduce(0, +) / n
        let meanY = y.reduce(0, +) / n
        var num = 0.0, denX = 0.0, denY = 0.0
        for (xi, yi) in zip(x, y) {
            let dx = xi - meanX, dy = yi - meanY
            num += dx * dy
            denX += dx * dx
            denY += dy * dy
        }
        let den = (denX * denY).squareRoot()
        return den > 0 ? num / den : 0
    }

    // MARK: - Time of day

    private static func makeTimeOfDayShares(
        occurrences: [Occurrence],
        calendar: Calendar
    ) -> [ReportTimeOfDayShare] {
        let childRanges = interruptChildRanges(occurrences)
        // type → segment → hours
        var acc: [String: [ReportTimeOfDaySegment: Double]] = [:]
        // Distinct days each type appears on — a share computed from one or
        // two days is noise dressed as precision ("reading: morning=100%"
        // from a single session), so such types are dropped below.
        var daysByType: [String: Set<Date>] = [:]
        for occ in occurrences {
            let children = childRanges[occ.event.id] ?? []
            // Net whole hours drives the total; segment split uses the raw
            // range (interrupt netting only scales the magnitude, not which
            // segment the time sits in — a small acceptable simplification).
            let net = netWholeHours(occ, childRanges: children)
            guard net > 0 else { continue }
            let segmentSeconds = segmentSeconds(for: occ.range, calendar: calendar)
            let grossSeconds = segmentSeconds.values.reduce(0, +)
            guard grossSeconds > 0 else { continue }
            let day = calendar.startOfDay(for: occ.range.start)
            for (type, weight) in normalizedTypeWeights(for: occ.event) {
                daysByType[type, default: []].insert(day)
                for (segment, seconds) in segmentSeconds {
                    let hours = net * (seconds / grossSeconds) * weight
                    acc[type, default: [:]][segment, default: 0] += hours
                }
            }
        }
        return acc.compactMap { type, segmentHours -> ReportTimeOfDayShare? in
            guard (daysByType[type]?.count ?? 0) >= ReportTuning.minTimeOfDayDays else {
                return nil
            }
            let total = segmentHours.values.reduce(0, +)
            let shares = total > 0
                ? segmentHours.mapValues { $0 / total }
                : segmentHours
            return ReportTimeOfDayShare(type: type, shares: shares)
        }
        .sorted { $0.type < $1.type }
    }

    // Seconds an occurrence spends in each day segment, summed across every day
    // it touches (a cross-midnight session contributes to segments on both days).
    private static func segmentSeconds(
        for range: Event.TimeRange,
        calendar: Calendar
    ) -> [ReportTimeOfDaySegment: Double] {
        var result: [ReportTimeOfDaySegment: Double] = [:]
        var day = calendar.startOfDay(for: range.start)
        let lastDay = calendar.startOfDay(for: range.end)
        while day <= lastDay {
            for segment in ReportTimeOfDaySegment.allCases {
                for interval in segment.hourIntervals {
                    guard let segStart = calendar.date(bySettingHour: interval.start % 24, minute: 0, second: 0, of: day),
                          let segEnd = intervalEnd(interval.end, day: day, calendar: calendar) else { continue }
                    let overlap = max(0, min(range.end, segEnd).timeIntervalSince(max(range.start, segStart)))
                    if overlap > 0 { result[segment, default: 0] += overlap }
                }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return result
    }

    // End of a segment interval within `day`; hour 24 means the next midnight.
    private static func intervalEnd(_ hour: Int, day: Date, calendar: Calendar) -> Date? {
        if hour >= 24 {
            return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day))
        }
        return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day)
    }

    // MARK: - perTypeHours assembly

    private static func makeTypeHours(
        current: [String: Double],
        previous: [String: Double],
        isThin: Bool
    ) -> [ReportTypeHours] {
        let allTypes = Set(current.keys).union(previous.keys)
        return allTypes.map { type in
            let cur = current[type] ?? 0
            let prev = previous[type] ?? 0
            let delta = cur - prev
            let deltaPercent: Double? = prev > 0 ? (delta / prev) * 100 : nil
            return ReportTypeHours(
                type: type,
                hours: cur,
                previousHours: prev,
                deltaHours: delta,
                deltaPercent: deltaPercent,
                tier: deltaTier(current: cur, previous: prev, isThin: isThin)
            )
        }
        .sorted { $0.hours > $1.hours }
    }

    // Confidence tier for a week-over-week delta.  A category that barely
    // appears in either window is noise (`low`); otherwise the relative change
    // sets the tier, and thin windows are capped at `medium` so the wording
    // stays soft when the whole report rests on little data.
    private static func deltaTier(current: Double, previous: Double, isThin: Bool) -> ReportConfidenceTier {
        let base = max(current, previous)
        guard base >= ReportTuning.deltaNoiseFloorHours else { return .low }
        let relative = abs(current - previous) / base
        let raw: ReportConfidenceTier
        if relative >= ReportTuning.deltaHighRelative {
            raw = .high
        } else if relative >= ReportTuning.deltaMediumRelative {
            raw = .medium
        } else {
            raw = .low
        }
        return isThin ? min(raw, .medium) : raw
    }

    // MARK: - Day helpers

    private static func calendarDays(from start: Date, to end: Date, calendar: Calendar) -> [Date] {
        var days: [Date] = []
        var current = calendar.startOfDay(for: start)
        let boundary = end
        while current < boundary {
            days.append(current)
            guard let next = calendar.date(byAdding: .day, value: 1, to: current) else { break }
            current = next
        }
        return days
    }

    private static func dayEnd(_ day: Date, _ calendar: Calendar) -> Date {
        calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day))
            ?? calendar.startOfDay(for: day)
    }
}

private extension Double {
    /// -1 / 0 / +1 sign, with exact zero mapping to 0 (no direction).
    var sign01: Int {
        if self > 0 { return 1 }
        if self < 0 { return -1 }
        return 0
    }
}
