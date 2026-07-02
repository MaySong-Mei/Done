//
//  ReportModels.swift
//  Done
//
//  Value-type model layer for the generative report system (Discussion #111).
//
//  A report is a *no-imply* deep data analysis: it lays out relationships
//  across the user's own categories (share of time, this-window vs the
//  previous equal-length window, category × category association) and only
//  points downward — a single line of notable tension — where the data is
//  confident enough to warrant it.  It never infers motive or emotion, never
//  advises, never praises.  Every number is computed here and handed to the
//  language model verbatim; the model only chooses wording and must quote the
//  figures exactly as given, never recomputing them.
//
//  These types are pure Foundation value types with no reference to a store,
//  a `@MainActor` object, or the current wall-clock — they can be built and
//  serialized off the main thread.  See `ReportStatsBuilder`.
//

import Foundation

/// Confidence is the licence for how hard the wording may be: `high` lets the
/// report state a relationship directly (and add a light nudge); `medium`
/// only exposes the bare relationship; `low` is dropped from the prompt so
/// the model never sees it.  Ordering is `low < medium < high`.
enum ReportConfidenceTier: String, Codable, Comparable, CaseIterable {
    case low
    case medium
    case high

    private var rank: Int {
        switch self {
        case .low: return 0
        case .medium: return 1
        case .high: return 2
        }
    }

    static func < (lhs: ReportConfidenceTier, rhs: ReportConfidenceTier) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// The three raw signals that decide a relationship entry's tier.
///
/// - `overlapDays`: number of days in the window where *both* sides of the
///   relationship actually have a record (the sample size the statistic rests
///   on — days where one side is empty carry no information about the pair).
/// - `consistency`: cross-half-window sign agreement in `0...1`.  The window is
///   split in two; a relationship whose direction flips between halves is not
///   trustworthy regardless of its magnitude.
/// - `effectSize`: magnitude of the relationship (e.g. `|r|` for a correlation,
///   or relative change for a week-over-week delta).
struct ReportConfidenceInput: Codable, Hashable {
    var overlapDays: Int
    var consistency: Double
    var effectSize: Double

    var tier: ReportConfidenceTier {
        ReportConfidenceThresholds.tier(for: self)
    }
}

/// Single source of truth for every gating threshold — tuning the report's
/// "how hard may it speak" policy means editing only this enum.
enum ReportConfidenceThresholds {
    /// `high`: enough overlapping days, a strong effect, and a direction that
    /// held across both halves of the window.
    static let highMinOverlapDays = 5
    static let highMinEffectSize = 0.6
    static let highMinConsistency = 1.0

    /// `medium`: a moderate sample and a moderate effect; no consistency
    /// requirement (medium only ever exposes the bare relationship).
    static let mediumMinOverlapDays = 3
    static let mediumMinEffectSize = 0.4

    static func tier(for input: ReportConfidenceInput) -> ReportConfidenceTier {
        if input.overlapDays >= highMinOverlapDays,
           input.effectSize >= highMinEffectSize,
           input.consistency >= highMinConsistency {
            return .high
        }
        if input.overlapDays >= mediumMinOverlapDays,
           input.effectSize >= mediumMinEffectSize {
            return .medium
        }
        return .low
    }
}

/// Structural / shaping constants (thin-data cutoffs, pair fan-out, time-of-day
/// boundaries, prompt budgeting).  Kept apart from `ReportConfidenceThresholds`
/// so the confidence policy and the report shape can be tuned independently.
enum ReportTuning {
    /// A window is "thin" (report should stay short and soft) if it has fewer
    /// than this many recorded days or fewer than this many events.
    static let thinMinRecordedDays = 4
    static let thinMinEvents = 12

    /// Only the top-N categories by total time are paired for correlation, to
    /// keep the cross-product small and the relationships meaningful.
    static let maxPairTypes = 6

    /// A week-over-week delta below this many hours on both sides is treated as
    /// noise (its category barely appears in either window) → `low`.
    static let deltaNoiseFloorHours = 2.0

    /// Time-of-day shares are only computed for categories seen on at least
    /// this many distinct days — a percentage built from one or two sessions
    /// is noise dressed as precision.
    static let minTimeOfDayDays = 3
    /// Relative-change cut-offs (|delta| / max(previous, current)) for the delta
    /// effect size feeding `ReportConfidenceInput.effectSize`.
    static let deltaHighRelative = 0.5
    static let deltaMediumRelative = 0.25

    /// Coarse token estimate: `tokens ≈ characters / 3`.  A rough English/CJK
    /// average, deliberately conservative — this is a budgeting guard, not an
    /// accounting of real tokenizer output.
    static let charsPerToken = 3
}

/// The four coarse day segments a category's time is distributed across.
/// `night` wraps midnight, so it owns two hour intervals within a day.  Bounds
/// are half-open `[startHour, endHour)` in local calendar hours.
enum ReportTimeOfDaySegment: String, Codable, CaseIterable {
    case morning
    case afternoon
    case evening
    case night

    /// Hour intervals `[start, end)` this segment occupies within one local
    /// day.  `night` returns two intervals because it straddles midnight.
    var hourIntervals: [(start: Int, end: Int)] {
        switch self {
        case .morning: return [(5, 12)]
        case .afternoon: return [(12, 17)]
        case .evening: return [(17, 21)]
        case .night: return [(21, 24), (0, 5)]
        }
    }
}

/// Window metadata: the frame every number in the report is measured against.
struct ReportWindowMeta: Codable, Hashable {
    var start: Date
    var end: Date
    /// Calendar days spanned by `[start, end)`.
    var dayCount: Int
    /// Days in `[start, end)` that carry at least one record.
    var recordedDayCount: Int
    /// Distinct events with at least one occurrence in `[start, end)`.
    var eventCount: Int
    /// Sparse-data flag: keep the report short and the wording soft.
    var isThin: Bool
}

/// Total time a category held in the window, with the previous equal-length
/// window as a comparison baseline.  `tier` gates whether the delta is hard
/// enough to surface as a notable change.
struct ReportTypeHours: Codable, Hashable {
    /// The user's own category word — never a hard-coded semantic label.
    var type: String
    var hours: Double
    var previousHours: Double
    var deltaHours: Double
    /// `nil` when the previous window had no time for this category (the
    /// percentage would divide by zero — the model should speak in absolutes).
    var deltaPercent: Double?
    var tier: ReportConfidenceTier
}

/// One day's total scheduled hours, cross-midnight occurrences split at the
/// day boundary — matches the Analysis chart's daily semantics.
struct ReportDailyTotal: Codable, Hashable {
    var date: Date
    var hours: Double
}

/// One day's hours for a single category under the **whole-occurrence**
/// attribution (cross-midnight fixed): the occurrence is not split, it lands
/// entirely on the day it overlaps more.  Feeds the relationship math.
struct ReportTypeDayHours: Codable, Hashable {
    var type: String
    var date: Date
    var hours: Double
}

/// Pearson correlation between two categories' daily hours (from `sessionDaily`).
struct ReportTypePairRelation: Codable, Hashable {
    var typeA: String
    var typeB: String
    /// Pearson r in `-1...1` over the window's *recorded* days (days with no
    /// record at all are excluded — their (0, 0) points would fabricate a
    /// positive co-absence correlation).
    var correlation: Double
    var confidence: ReportConfidenceInput

    var tier: ReportConfidenceTier { confidence.tier }
}

/// A category's fraction of time in each day segment (values sum to ~1 when the
/// category has any time).  The builder omits empty categories and categories
/// seen on fewer than `ReportTuning.minTimeOfDayDays` distinct days.
struct ReportTimeOfDayShare: Codable, Hashable {
    var type: String
    var shares: [ReportTimeOfDaySegment: Double]
}

/// The full statistical payload for one report window.  Everything is
/// pre-computed; `promptText` serializes it for the language model.
struct ReportStats: Codable, Hashable {
    var window: ReportWindowMeta
    var perTypeHours: [ReportTypeHours]
    var dailyTotals: [ReportDailyTotal]
    /// Whole-occurrence, per-category, per-day series — the cross-midnight-fixed
    /// counterpart to `dailyTotals`.  Kept separate because relationship math
    /// needs a category's time to sit on one day (a session split across
    /// midnight would fabricate a spurious two-day pattern), whereas the daily
    /// *total* must stay faithful to the calendar the way the chart draws it.
    var sessionDaily: [ReportTypeDayHours]
    var typePairRelations: [ReportTypePairRelation]
    var timeOfDayShares: [ReportTimeOfDayShare]

    /// Serializes the stats into the data block handed to the language model,
    /// ordered so the most licensed material survives truncation:
    ///
    ///   1. window frame (always),
    ///   2. category hours + previous-window baseline (the horizontal data),
    ///   3. high-confidence relationships, then medium,
    ///   4. time-of-day distribution (lowest priority).
    ///
    /// Confidence gating happens here: `low`-tier relationships are never
    /// emitted.  `budget` is a coarse token budget (`tokens ≈ chars / 3`,
    /// `ReportTuning.charsPerToken`); once a line would push the running
    /// estimate past `budget`, emission stops.
    ///
    /// `includeChanges: false` drops every previous-window comparison (the
    /// CATEGORY prev/delta fields and all CHANGE lines) — used when the report
    /// is generated before the window has closed, where a partial total
    /// against a full previous window would mislead by construction.
    func promptText(budget: Int, includeChanges: Bool = true) -> String {
        let budgetChars = max(0, budget) * ReportTuning.charsPerToken
        var lines: [String] = []
        var usedChars = 0

        // Appends `line` only if it still fits the character budget; returns
        // false once the budget is exhausted so callers can stop early.
        func append(_ line: String) -> Bool {
            let cost = line.count + 1 // + newline
            guard usedChars + cost <= budgetChars else { return false }
            lines.append(line)
            usedChars += cost
            return true
        }

        func fmt(_ value: Double) -> String { String(format: "%.1f", value) }

        // 1. Window frame.
        let dayFormatter = ISO8601DateFormatter()
        dayFormatter.formatOptions = [.withFullDate]
        _ = append("WINDOW \(dayFormatter.string(from: window.start)) .. \(dayFormatter.string(from: window.end)) "
            + "days=\(window.dayCount) recordedDays=\(window.recordedDayCount) events=\(window.eventCount)"
            + (window.isThin ? " sparse=true" : ""))

        // 2. Category hours (horizontal base data), largest first.
        for entry in perTypeHours.sorted(by: { $0.hours > $1.hours }) {
            let line: String
            if includeChanges {
                let delta: String
                if let pct = entry.deltaPercent {
                    delta = "delta=\(fmt(entry.deltaHours))h (\(fmt(pct))%)"
                } else {
                    delta = "delta=\(fmt(entry.deltaHours))h (new)"
                }
                line = "CATEGORY \(entry.type): \(fmt(entry.hours))h prev=\(fmt(entry.previousHours))h \(delta)"
            } else {
                line = "CATEGORY \(entry.type): \(fmt(entry.hours))h"
            }
            if !append(line) { return lines.joined(separator: "\n") }
        }

        // 3. Relationships, confidence-descending, low tier dropped entirely.
        var relations: [(tier: ReportConfidenceTier, effect: Double, text: String)] = []
        if includeChanges {
            for entry in perTypeHours where entry.tier > .low {
                let dir = entry.deltaHours >= 0 ? "up" : "down"
                relations.append((
                    entry.tier,
                    abs(entry.deltaHours),
                    "CHANGE \(entry.type) \(dir) by \(fmt(abs(entry.deltaHours)))h vs previous window [\(entry.tier.rawValue)]"
                ))
            }
        }
        for pair in typePairRelations where pair.tier > .low {
            relations.append((
                pair.tier,
                abs(pair.correlation),
                "RELATION \(pair.typeA) ~ \(pair.typeB) r=\(fmt(pair.correlation)) "
                    + "overlapDays=\(pair.confidence.overlapDays) [\(pair.tier.rawValue)]"
            ))
        }
        for relation in relations.sorted(by: {
            $0.tier != $1.tier ? $0.tier > $1.tier : $0.effect > $1.effect
        }) {
            if !append(relation.text) { return lines.joined(separator: "\n") }
        }

        // 4. Time-of-day distribution (lowest priority).  The builder already
        // withholds shares for categories seen on fewer than
        // `ReportTuning.minTimeOfDayDays` distinct days, so whatever is here
        // rests on enough days to be worth saying.
        for share in timeOfDayShares {
            let parts = ReportTimeOfDaySegment.allCases.compactMap { segment -> String? in
                guard let value = share.shares[segment], value > 0 else { return nil }
                return "\(segment.rawValue)=\(fmt(value * 100))%"
            }
            guard !parts.isEmpty else { continue }
            if !append("WHEN \(share.type): \(parts.joined(separator: " "))") {
                return lines.joined(separator: "\n")
            }
        }

        return lines.joined(separator: "\n")
    }
}
