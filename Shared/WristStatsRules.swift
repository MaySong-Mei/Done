//
//  WristStatsRules.swift
//  Shared (Done + DoneWatch)
//
//  What the watch's stats page counts, as the phone's Settings → Apple
//  Watch chose it, and the arithmetic that counts it. The phone owns the
//  choice and sends it in every `WristSnapshot`; the watch applies it to
//  the widget's slices. Pure, so DoneTests can pin every rule.
//

import Foundation

/// How a stretch of time that several events cover is credited.
nonisolated enum WristOverlapRule: String, CaseIterable, Codable, Sendable {
    /// Each covering event gets an equal share — the Analysis tab's and the
    /// widget's rule. The rows add up to the time logged.
    case split
    /// Every type that covers the stretch gets all of it, once (two
    /// overlapping events of one type still count that type once). A row
    /// never exceeds the time that passed; the rows together can.
    case full
    /// The event started most recently takes the stretch (the shorter one
    /// when they started together): whatever you started last is what you
    /// were doing. The rows add up to the time logged.
    case latestStart
}

/// The phone's Settings → Apple Watch, as the watch needs it. Every field
/// decodes to its default when missing, so a snapshot from a phone without
/// the section reads as the stats page always was.
nonisolated struct WristStatsSettings: Codable, Equatable, Sendable {
    var overlap: WristOverlapRule = .split
    /// Types the stats leave out, by category name (case-insensitive).
    /// A list of what is left out, not of what counts, so a type made
    /// after the choice counts.
    var excludedTypes: [String] = []
    /// Also leave out the Me tab's background types
    /// (`CategoryStatsPayload.backgroundCategories`).
    var excludesBackground = false
    /// The period the stats page opens on.
    var defaultPeriod: WristStatsPeriod = .today

    static let standard = WristStatsSettings()

    init(
        overlap: WristOverlapRule = .split, excludedTypes: [String] = [],
        excludesBackground: Bool = false, defaultPeriod: WristStatsPeriod = .today
    ) {
        self.overlap = overlap
        self.excludedTypes = excludedTypes
        self.excludesBackground = excludesBackground
        self.defaultPeriod = defaultPeriod
    }

    private enum CodingKeys: String, CodingKey {
        case overlap, excludedTypes, excludesBackground, defaultPeriod
    }

    /// A rule or period this build does not know reads as the default
    /// rather than failing the whole snapshot.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        overlap = (try? c.decodeIfPresent(String.self, forKey: .overlap)).flatMap { $0 }
            .flatMap(WristOverlapRule.init(rawValue:)) ?? .split
        excludedTypes = (try? c.decodeIfPresent([String].self, forKey: .excludedTypes)).flatMap { $0 } ?? []
        excludesBackground = (try? c.decodeIfPresent(Bool.self, forKey: .excludesBackground)).flatMap { $0 } ?? false
        defaultPeriod = (try? c.decodeIfPresent(String.self, forKey: .defaultPeriod)).flatMap { $0 }
            .flatMap(WristStatsPeriod.init(rawValue:)) ?? .today
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(overlap.rawValue, forKey: .overlap)
        try c.encode(excludedTypes, forKey: .excludedTypes)
        try c.encode(excludesBackground, forKey: .excludesBackground)
        try c.encode(defaultPeriod.rawValue, forKey: .defaultPeriod)
    }

    /// Whether `name` is left out, given the payload's background list.
    func excludes(_ name: String, background: [String]?) -> Bool {
        let picked = Set(excludedTypes.map { $0.lowercased() })
        if picked.contains(name.lowercased()) { return true }
        return excludesBackground && MeBackgroundTypes.contains(name, in: Set(background ?? []))
    }
}

extension CategoryStatsPayload {
    /// The payload with the categories `settings` leaves out marked
    /// (`Category.leftOut`), and nothing else changed. What the watch's
    /// pages read, so the today page's clock row and the stats page agree
    /// on what counts.
    nonisolated func markingLeftOut(_ settings: WristStatsSettings) -> CategoryStatsPayload {
        guard settings.excludesBackground || !settings.excludedTypes.isEmpty, let categories else { return self }
        var copy = self
        copy.categories = categories.map { category in
            var marked = category
            if let name = category.name, settings.excludes(name, background: backgroundCategories) {
                marked.leftOut = true
            }
            return marked
        }
        return copy
    }
}

/// One span's time as the watch counts it.
nonisolated struct WristStatsTally: Equatable {
    /// Hours per category name under the overlap rule; left-out categories
    /// have none.
    var hours: [String: Double] = [:]
    /// Wall-clock hours at least one counted type covers. The same under
    /// every rule.
    var loggedHours: Double = 0
    /// Wall-clock hours only left-out types cover: neither logged nor
    /// unlogged, taken out of the period.
    var leftOutHours: Double = 0

    /// The slices of `payload` in `span`'s days, cut at `asOf` — the
    /// walk `CategoryStats.hours` makes — credited by `overlap`. Left-out
    /// categories (`Category.leftOut`) do not compete for a slice: a slice
    /// they share with counted types goes to those types as if they were
    /// not there.
    static func of(
        _ payload: CategoryStatsPayload, span: (start: Date, end: Date), asOf: Date, overlap: WristOverlapRule
    ) -> WristStatsTally {
        let calendar = payload.resolvedCalendar()
        var buckets: [Date: CategoryStatsPayload.Day] = [:]
        for day in payload.days ?? [] {
            guard let start = day.start, buckets[start] == nil else { continue }
            buckets[start] = day
        }
        let categories = payload.categories ?? []
        func isLeftOut(_ index: Int) -> Bool { categories[index].leftOut == true }

        var tally = WristStatsTally()
        var byIndex: [Int: Double] = [:]
        for day in CategoryStats.days(from: span.start, to: span.end, calendar: calendar) {
            guard let bucket = buckets[calendar.startOfDay(for: day)] else { continue }
            for slice in bucket.slices ?? [] {
                guard let start = slice.start, let end = slice.end, let n = slice.n, n > 0 else { continue }
                let cut = min(end, asOf)
                guard cut > start else { continue }
                let length = cut.timeIntervalSince(start) / 3600
                let entries = zip(slice.categoryIndices ?? [], slice.counts ?? [])
                    .filter { categories.indices.contains($0.0) && $0.1 > 0 }
                let counted = entries.filter { !isLeftOut($0.0) }
                guard !counted.isEmpty else {
                    if !entries.isEmpty { tally.leftOutHours += length }
                    continue
                }
                tally.loggedHours += length

                func split() {
                    // With nothing left out this is the widget's own
                    // `length / n * count`, term for term.
                    let leftOutCount = entries.filter { isLeftOut($0.0) }.reduce(0) { $0 + $1.1 }
                    let shares = n - leftOutCount > 0 ? n - leftOutCount : counted.reduce(0) { $0 + $1.1 }
                    let each = length / Double(shares)
                    for (index, count) in counted { byIndex[index, default: 0] += each * Double(count) }
                }
                switch overlap {
                case .split:
                    split()
                case .full:
                    for (index, _) in counted { byIndex[index, default: 0] += length }
                case .latestStart:
                    if counted.count == 1 {
                        byIndex[counted[0].0, default: 0] += length
                    } else if payload.winners == true, let winner = slice.categoryIndices?.first,
                              counted.contains(where: { $0.0 == winner }) {
                        byIndex[winner, default: 0] += length
                    } else {
                        // A payload from a phone before the winners were
                        // written, or a winner that is left out: who would
                        // be next is not known, so the rest split.
                        split()
                    }
                }
            }
        }
        for (index, value) in byIndex {
            guard let name = categories[index].name else { continue }
            tally.hours[name, default: 0] += value
        }
        return tally
    }
}

/// Which of the occurrences covering one slice `latestStart` gives it to:
/// the latest start, then the shorter, then the first category name. Lives
/// here so the phone writes it (`CategoryStatsBuilder`) and the tests state
/// it in one place.
nonisolated enum WristForeground {
    struct Candidate: Equatable {
        var category: String
        var start: Date
        var end: Date
    }

    /// The winning candidate's category.
    static func winner(_ candidates: [Candidate]) -> String? {
        candidates.min { a, b in
            if a.start != b.start { return a.start > b.start }
            let la = a.end.timeIntervalSince(a.start), lb = b.end.timeIntervalSince(b.start)
            if la != lb { return la < lb }
            return a.category < b.category
        }?.category
    }
}

/// The watch's own settings, kept on the watch (its `@AppStorage`) and
/// never sent to the phone: how tall an hour is on the today page, and the
/// period the stats page opens on when the user picked one on the watch.
nonisolated enum WristLocalSettings {
    static let zoomKey = "wrist.zoom"
    static let statsPeriodKey = "wrist.statsPeriod"

    /// The today page's scale. Medium is the page as it always was.
    enum Zoom: String, CaseIterable, Sendable {
        case small, medium, large

        static let standard = Zoom.medium

        /// Points per hour of the day.
        var hourHeight: Double {
            switch self {
            case .small: return 44
            case .medium: return 64
            case .large: return 88
            }
        }

        /// A stored value; anything unknown (or nothing) is the standard.
        init(stored: String?) {
            self = stored.flatMap(Zoom.init(rawValue:)) ?? .standard
        }
    }

    /// The period the stats page opens on: the one picked on the watch,
    /// else the phone's (Settings → Apple Watch). Empty or unknown stored
    /// text means none was picked on the watch.
    static func openingPeriod(watch stored: String?, phone: WristStatsPeriod) -> WristStatsPeriod {
        stored.flatMap(WristStatsPeriod.init(rawValue:)) ?? phone
    }
}
