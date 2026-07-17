//
//  ReportClueBuilder.swift
//  Done
//
//  Deterministic clue battery for the report system (Discussion #111,
//  clue-search design finalized 2026-07-16 — Docs/report-clue-search-panel-
//  2026-07-15.md).  Slice A: daily windows only; weekly/monthly detectors
//  follow as independent slices.
//
//  A clue is a code-computed finding: today measured against this person's own
//  trailing baseline.  The battery is what makes a daily report more than a
//  chronological retelling — it computes what the person can't compute in
//  their head (the "算出我算不出的" retention lever), and every figure it
//  emits is deterministic, frozen with the report, and quoted verbatim by the
//  model.
//
//  Discipline (from the panel, enforced by construction):
//    * Pure like `ReportStatsBuilder`: no `Date()`, no store — the observation
//      cutoff is the injected `asOf`, prior fingerprints arrive as a value.
//    * Every hour figure comes from `ReportStatsBuilder.sharedWeightedTypeHours`
//      — the same overlap-shared, interrupt-netted, weight-distributed
//      accounting as the DATA block's CATEGORY lines (#116 discipline: no
//      consumer computes hours its own way).
//    * Baselines are ELAPSED-CLAMPED: a report generated at 15:00 compares
//      "today by 15:00" against "each lookback day by 15:00", so a partial
//      day never reads as "less" against full days (panel hard prerequisite).
//    * Confidence reuses the three-signal gating with `overlapDays`
//      REINTERPRETED for baseline detectors as "history sample days behind the
//      baseline" (panel hard prerequisite — a single-day window has no pair
//      overlap to count).
//    * Novelty: a clue whose fingerprint a recent same-kind report already
//      told is suppressed — the mechanical defense against repeat-the-weather.
//      A direction flip is a new fingerprint and passes.
//

import Foundation

enum ReportClueBuilder {

    /// What the battery produced for one generation — kept whole for the
    /// Developer page's emission observability (candidates vs selected vs
    /// novelty-suppressed is how "is code-side selection good enough" gets
    /// answered with data instead of anecdotes; see the pass-1 trigger
    /// conditions in the panel doc).
    struct Emission {
        /// Every clue that cleared its detector's gates (tier > low), before
        /// novelty and caps.
        var candidates: [ReportClue]
        /// The clues that go to the model, strongest first.
        var selected: [ReportClue]
        /// Candidates dropped because a recent report already told them.
        var noveltySuppressedCount: Int
        /// Start of the lookback window the baselines rest on.
        var historyStart: Date

        static let empty = Emission(
            candidates: [], selected: [], noveltySuppressedCount: 0,
            historyStart: .distantPast
        )
    }

    // MARK: - Entry point

    /// Runs the battery for `[start, end)` with trailing history.  `events`
    /// must be the same set `ReportStatsBuilder.build` receives (the
    /// canvasRenderable contract) and must cover the lookback span — callers
    /// pass the full store array; expansion filters precisely.
    ///
    /// `asOf` is the observation cutoff (the report's own `createdAt`): both
    /// today's figures and every baseline sub-window are clamped to the same
    /// elapsed fraction.  Pass a moment past `end` for a complete window.
    ///
    /// Slice A scope: non-daily windows return `.empty` — their detector
    /// families (WoW delta, share drift, correlation flips…) are separate
    /// slices per the panel plan.
    static func build(
        events: [Event],
        logRecords: [CalendarEventLogRecord],
        start: Date,
        end: Date,
        asOf: Date,
        calendar: Calendar,
        priorFingerprints: Set<String>
    ) -> Emission {
        guard ReportPeriodKind.of(start: start, end: end, calendar: calendar) == .daily else {
            return .empty
        }
        guard let historyStart = calendar.date(
            byAdding: .day, value: -ReportTuning.clueLookbackDaysDaily, to: start
        ) else { return .empty }

        let cut = min(max(asOf, start), end)
        let isPartial = cut < end
        // Seconds into the day that "so far" covers; a complete window clamps
        // to nothing (full days on both sides).
        let elapsed = cut.timeIntervalSince(start)

        let occurrences = ReportStatsBuilder.expandOccurrences(
            events: events, windowStart: historyStart, windowEnd: end, calendar: calendar
        )

        // Per-day presence (any occurrence overlapping the FULL day) for the
        // streak/emergence detectors, matching `recordedDayCount` semantics.
        // NOTE: this deliberately reads the report contract set
        // (canvasRenderable, via `events`) — it diverges from
        // `AnalysisViewModel.recordStreak`, which intentionally uses raw
        // events; the report speaks about the same data it charts.
        var historyDays: [Date] = []
        var day = calendar.startOfDay(for: historyStart)
        while day < start {
            historyDays.append(day)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        func fullDayHours(_ day: Date) -> [String: Double] {
            ReportStatsBuilder.sharedWeightedTypeHours(
                occurrences: occurrences,
                windowStart: day,
                windowEnd: calendar.date(byAdding: .day, value: 1, to: day) ?? day
            )
        }
        func clampedDayHours(_ day: Date) -> [String: Double] {
            guard isPartial else { return fullDayHours(day) }
            return ReportStatsBuilder.sharedWeightedTypeHours(
                occurrences: occurrences,
                windowStart: day,
                windowEnd: day.addingTimeInterval(elapsed)
            )
        }

        let fullByDay: [Date: [String: Double]] = Dictionary(
            uniqueKeysWithValues: historyDays.map { ($0, fullDayHours($0)) }
        )
        let recordedHistoryDays = historyDays.filter { !(fullByDay[$0] ?? [:]).isEmpty }
        let clampedByDay: [Date: [String: Double]] = Dictionary(
            uniqueKeysWithValues: recordedHistoryDays.map { ($0, clampedDayHours($0)) }
        )
        let todayClamped = clampedDayHours(start)
        let todayFull = fullDayHours(start)

        var candidates: [ReportClue] = []
        candidates += deviationClues(
            todayClamped: todayClamped,
            clampedByDay: clampedByDay,
            recordedHistoryDays: recordedHistoryDays,
            windowStart: start, cut: cut, isPartial: isPartial,
            calendar: calendar
        )
        candidates += overrunClue(
            occurrences: occurrences, logRecords: logRecords,
            start: start, cut: cut
        )
        candidates += emergenceClues(
            todayFull: todayFull, fullByDay: fullByDay,
            historyDays: historyDays, windowStart: start, calendar: calendar
        )
        candidates += absenceClues(
            todayClamped: todayClamped, todayFull: todayFull,
            clampedByDay: clampedByDay,
            recordedHistoryDays: recordedHistoryDays,
            cut: cut, isPartial: isPartial, calendar: calendar
        )
        candidates += streakClues(
            todayRecorded: !todayFull.isEmpty,
            fullByDay: fullByDay, historyDays: historyDays,
            windowComplete: !isPartial
        )

        // --- Code-side selection: tier desc, effect desc; novelty; caps. ----
        let ranked = candidates.sorted {
            $0.tier != $1.tier ? $0.tier > $1.tier : $0.effect > $1.effect
        }
        var selected: [ReportClue] = []
        var perKind: [ReportClueKind: Int] = [:]
        var suppressed = 0
        for clue in ranked {
            if priorFingerprints.contains(clue.fingerprint) {
                suppressed += 1
                continue
            }
            guard perKind[clue.kind, default: 0] < ReportTuning.clueMaxPerKind else { continue }
            selected.append(clue)
            perKind[clue.kind, default: 0] += 1
            if selected.count == ReportTuning.clueMaxSelected { break }
        }

        return Emission(
            candidates: candidates,
            selected: selected,
            noveltySuppressedCount: suppressed,
            historyStart: historyStart
        )
    }

    // MARK: - Detector: typical-day deviation

    // Today vs the median of the person's own recent days, same elapsed
    // sub-window.  Same-weekday baseline preferred when it has enough samples
    // (a Sunday should be measured against Sundays); zero-days of RECORDED
    // days stay in the sample (they are real "none that day" observations),
    // unrecorded days carry no information and stay out.
    private static func deviationClues(
        todayClamped: [String: Double],
        clampedByDay: [Date: [String: Double]],
        recordedHistoryDays: [Date],
        windowStart: Date,
        cut: Date,
        isPartial: Bool,
        calendar: Calendar
    ) -> [ReportClue] {
        let weekday = calendar.component(.weekday, from: windowStart)
        let sameWeekday = recordedHistoryDays.filter {
            calendar.component(.weekday, from: $0) == weekday
        }
        let sample = sameWeekday.count >= ReportTuning.clueSameWeekdayMinSamples
            ? sameWeekday : recordedHistoryDays
        guard !sample.isEmpty else { return [] }
        let sampleLabel = sample.count == sameWeekday.count && sample.count != recordedHistoryDays.count
            ? "same-weekday" : "recorded"

        var clues: [ReportClue] = []
        for (type, today) in todayClamped where today > 0 {
            let series = sample.map { clampedByDay[$0]?[type] ?? 0 }
            let typical = median(series)
            // median == 0 is emergence territory, not a deviation.
            guard typical > 0 else { continue }
            guard max(today, typical) >= ReportTuning.clueDeviationNoiseFloorHours else { continue }
            let relative = abs(today - typical) / max(today, typical)
            // Baseline stability doubles as the consistency signal: a spread-out
            // baseline can't license a hard "unusual today".
            let spread = median(series.map { abs($0 - typical) })
            let stable = typical > 0 && spread / typical <= ReportTuning.clueDeviationMaxSpread
            // overlapDays reinterpreted: history sample days behind the baseline.
            let confidence = ReportConfidenceInput(
                overlapDays: sample.count,
                consistency: stable ? 1 : 0,
                effectSize: relative
            )
            let tier = confidence.tier
            guard tier > .low else { continue }
            let direction = today > typical ? "up" : "down"
            let frame = isPartial ? " by \(timeLabel(cut, calendar: calendar))" : ""
            let line = "CLUE deviation \(type): \(fmt(today))h\(frame) today vs \(fmt(typical))h typical\(frame) "
                + "(median of \(sample.count) \(sampleLabel) days) \(direction) [\(tier.rawValue)]"
            clues.append(ReportClue(
                kind: .deviation, type: type, direction: direction,
                tier: tier, effect: relative, line: line
            ))
        }
        return clues
    }

    // MARK: - Detector: plan vs actual (logged) duration

    // Aggregates today's logged occurrences that carry an actual duration and
    // compares against their scheduled length.  No history needed — works from
    // day one (cold-start coverage).  Whole-day aggregate: per-category
    // overrun is a later refinement.
    private static func overrunClue(
        occurrences: [ReportStatsBuilder.Occurrence],
        logRecords: [CalendarEventLogRecord],
        start: Date,
        cut: Date
    ) -> [ReportClue] {
        let logByKey = Dictionary(logRecords.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        var deltas: [Double] = []
        var totalScheduled = 0.0
        for occ in occurrences where occ.range.start >= start && occ.range.start < cut {
            let key = CalendarOccurrenceKey.make(for: occ.event, occurrenceDate: occ.range.start)
            guard let actual = logByKey[key]?.actualDurationMinutes else { continue }
            let scheduled = occ.range.end.timeIntervalSince(occ.range.start) / 60
            guard scheduled > 0 else { continue }
            deltas.append(Double(actual) - scheduled)
            totalScheduled += scheduled
        }
        guard !deltas.isEmpty, totalScheduled > 0 else { return [] }
        let totalDelta = deltas.reduce(0, +)
        let relative = abs(totalDelta) / totalScheduled
        guard abs(totalDelta) >= ReportTuning.clueOverrunMinMinutes,
              relative >= ReportTuning.clueOverrunMediumRelative else { return [] }
        let sameSign = deltas.allSatisfy { $0 >= 0 } || deltas.allSatisfy { $0 <= 0 }
        let tier: ReportConfidenceTier =
            deltas.count >= 2 && sameSign && relative >= ReportTuning.clueOverrunHighRelative
            ? .high : .medium
        let direction = totalDelta > 0 ? "over" : "under"
        let sign = totalDelta > 0 ? "+" : "-"
        let line = "CLUE overrun: \(deltas.count) logged session\(deltas.count == 1 ? "" : "s") ran "
            + "\(sign)\(Int(abs(totalDelta).rounded()))min vs plan (\(sign)\(Int((relative * 100).rounded()))%) "
            + "\(direction) [\(tier.rawValue)]"
        return [ReportClue(
            kind: .overrun, type: "", direction: direction,
            tier: tier, effect: relative, line: line
        )]
    }

    // MARK: - Detector: emergence (first appearance / return)

    private static func emergenceClues(
        todayFull: [String: Double],
        fullByDay: [Date: [String: Double]],
        historyDays: [Date],
        windowStart: Date,
        calendar: Calendar
    ) -> [ReportClue] {
        var clues: [ReportClue] = []
        for (type, hours) in todayFull where hours > 0 {
            let lastSeen = historyDays.last { (fullByDay[$0]?[type] ?? 0) > 0 }
            if let lastSeen {
                let gap = calendar.dateComponents([.day], from: lastSeen, to: windowStart).day ?? 0
                guard gap >= ReportTuning.clueEmergenceMinGapDays else { continue }
                let line = "CLUE emergence \(type): back after \(gap) days away [medium]"
                clues.append(ReportClue(
                    kind: .emergence, type: type, direction: "return",
                    tier: .medium, effect: Double(gap), line: line
                ))
            } else {
                let line = "CLUE emergence \(type): first record in \(ReportTuning.clueLookbackDaysDaily) days [medium]"
                clues.append(ReportClue(
                    kind: .emergence, type: type, direction: "first",
                    tier: .medium, effect: Double(ReportTuning.clueLookbackDaysDaily), line: line
                ))
            }
        }
        return clues
    }

    // MARK: - Detector: habitual absence

    // Present on most recorded days (measured against the SAME elapsed
    // sub-window, so "missing by 15:00" only fires for a category that is
    // usually there by 15:00) yet absent today.
    private static func absenceClues(
        todayClamped: [String: Double],
        todayFull: [String: Double],
        clampedByDay: [Date: [String: Double]],
        recordedHistoryDays: [Date],
        cut: Date,
        isPartial: Bool,
        calendar: Calendar
    ) -> [ReportClue] {
        guard !recordedHistoryDays.isEmpty else { return [] }
        var presenceDays: [String: Int] = [:]
        for day in recordedHistoryDays {
            for (type, hours) in clampedByDay[day] ?? [:] where hours > 0 {
                presenceDays[type, default: 0] += 1
            }
        }
        var clues: [ReportClue] = []
        for (type, present) in presenceDays {
            // Full-day check too: a type merely late today (already scheduled
            // for tonight) is absent from the clamped window but not from the
            // day — saying "none today" would be wrong.
            guard (todayClamped[type] ?? 0) == 0, (todayFull[type] ?? 0) == 0 else { continue }
            let rate = Double(present) / Double(recordedHistoryDays.count)
            guard present >= ReportTuning.clueAbsenceMinPresenceDays,
                  rate >= ReportTuning.clueAbsenceMinPresenceRate else { continue }
            let tier: ReportConfidenceTier =
                present >= ReportTuning.clueAbsenceHighPresenceDays
                && rate >= ReportTuning.clueAbsenceHighPresenceRate ? .high : .medium
            let frame = isPartial ? " by \(timeLabel(cut, calendar: calendar))" : ""
            let line = "CLUE absence \(type): on \(present) of \(recordedHistoryDays.count) recorded days\(frame), "
                + "none today [\(tier.rawValue)]"
            clues.append(ReportClue(
                kind: .absence, type: type, direction: "absent",
                tier: tier, effect: rate, line: line
            ))
        }
        return clues
    }

    // MARK: - Detector: recording streak

    // Milestones fire on the day they are reached (today recorded, run length
    // hits a milestone); a break only fires on a COMPLETE window — "the run
    // ended" said at 09:00 about a day still underway would be fabrication.
    private static func streakClues(
        todayRecorded: Bool,
        fullByDay: [Date: [String: Double]],
        historyDays: [Date],
        windowComplete: Bool
    ) -> [ReportClue] {
        func recorded(_ day: Date) -> Bool { !(fullByDay[day] ?? [:]).isEmpty }
        // Run of consecutive recorded days ending at the last history day.
        var run = 0
        for day in historyDays.reversed() {
            guard recorded(day) else { break }
            run += 1
        }
        if todayRecorded {
            let length = run + 1
            guard ReportTuning.clueStreakMilestones.contains(length) else { return [] }
            let tier: ReportConfidenceTier = length >= ReportTuning.clueStreakHighLength ? .high : .medium
            let line = "CLUE streak: \(length) days in a row with records [\(tier.rawValue)]"
            return [ReportClue(
                kind: .streak, type: "", direction: "milestone-\(length)",
                tier: tier, effect: Double(length), line: line
            )]
        }
        guard windowComplete, run >= ReportTuning.clueStreakBreakMinLength else { return [] }
        let line = "CLUE streak: a \(run)-day recording run ended today (no records) [medium]"
        return [ReportClue(
            kind: .streak, type: "", direction: "break",
            tier: .medium, effect: Double(run), line: line
        )]
    }

    // MARK: - Small helpers

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[mid - 1] + sorted[mid]) / 2
            : sorted[mid]
    }

    private static func fmt(_ value: Double) -> String { String(format: "%.1f", value) }

    // Model-facing "by 15:04" cutoff label — POSIX-stable like the DATA block.
    private static func timeLabel(_ moment: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: moment)
    }
}
