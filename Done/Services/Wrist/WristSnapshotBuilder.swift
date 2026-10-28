//
//  WristSnapshotBuilder.swift
//  Done
//
//  Projects the store into the watch's `WristSnapshot`. Pure: events,
//  templates and a clock in; a snapshot out. The window is yesterday through
//  the day after tomorrow in the device's current calendar, so the watch can
//  resolve "now" by itself across day rollovers without the phone pushing.
//

import Foundation

enum WristSnapshotBuilder {
    /// The phone's motion switches as the watch plays them: each style by
    /// its raw value, so the two lists are the same list.
    static func motions(
        create: EventCreationMotionVariant?, delete: EventDeletionMotionVariant?, resize: EventResizeTweenVariant?
    ) -> WristMotionSettings {
        WristMotionSettings(
            create: create.flatMap { WristCreateStyle(rawValue: $0.rawValue) },
            delete: delete.flatMap { WristDeleteStyle(rawValue: $0.rawValue) },
            resize: resize.flatMap { WristResizePace(rawValue: $0.rawValue) }
        )
    }

    /// How many types the start grid shows.
    static let maxTypes = 8
    /// Types are ranked by how often they were used in this many days.
    static let usageWindowDays = 30
    /// A snapshot pushed late in the evening must still cover all of the
    /// next day and a margin beyond: the phone may not be touched for a while.
    static let dayOffsets = [-1, 0, 1, 2]

    static func snapshot(
        events: [Event],
        templates: [EventTypeTemplate],
        now: Date,
        calendar: Calendar,
        language: String?,
        receipts: [WristReceipt],
        stats: CategoryStatsPayload? = nil,
        statsSettings: WristStatsSettings = .standard,
        motions: WristMotionSettings = .off,
        colorHex: (String) -> String
    ) -> WristSnapshot {
        let types = rankedTypes(events: events, templates: templates, now: now, calendar: calendar)
        return WristSnapshot(
            generatedAt: now,
            language: language,
            types: types,
            occurrences: occurrences(events: events, now: now, calendar: calendar, colorHex: colorHex),
            receipts: receipts,
            stats: stats.flatMap { trimmed($0, now: now, reach: .thirtyDays) },
            statsSettings: statsSettings,
            titleHints: titleHints(events: events, types: types, now: now, calendar: calendar),
            takesSettingsEdits: true,
            takesRangeEdits: true,
            motions: motions
        )
    }

    /// How far back the stats the watch gets reach: every period the stats
    /// page offers (`thirtyDays`), or, when that does not fit, the last
    /// seven or only the last three days.
    enum StatsReach: CaseIterable {
        case thirtyDays, sevenDays, threeDays

        var periods: [WristStatsPeriod] {
            switch self {
            case .thirtyDays: return WristStatsPeriod.allCases
            case .sevenDays: return [.today, .threeDays, .sevenDays]
            case .threeDays: return [.today, .threeDays]
            }
        }
    }

    /// The widget's payload covers a month (or thirty days) and a week ahead, which on a busy
    /// calendar is more than WatchConnectivity carries. Keep the days of
    /// `reach`'s periods (in the payload's own calendar) plus the day before
    /// them — a watch whose clock reads a little earlier than the phone's at
    /// the turn of a period still finds it — and the days up to the end of
    /// the day after tomorrow, the same horizon as the occurrences: the phone
    /// pushes on changes, not on the clock, so the watch reads this payload
    /// hours or days after it was sent, across midnights and period
    /// boundaries. `coverageStart`/`End` say exactly what is kept, so a
    /// missing day can never read as an empty one, and a period the reach
    /// leaves out reads stale. Nil when the payload does not reach back that
    /// far.
    static func trimmed(_ payload: CategoryStatsPayload, now: Date, reach: StatsReach) -> CategoryStatsPayload? {
        let calendar = payload.resolvedCalendar()
        let reachStart = reach.periods.map { $0.span(asOf: now, calendar: calendar).start }.min() ?? now
        let keepFrom = calendar.date(byAdding: .day, value: -1, to: reachStart) ?? reachStart
        let today = calendar.startOfDay(for: now)
        let keepTo = calendar.date(byAdding: .day, value: horizonDays, to: today) ?? today
        guard let coverageStart = payload.coverageStart, let coverageEnd = payload.coverageEnd,
              coverageStart <= reachStart, coverageEnd > now else { return nil }
        var trimmed = payload
        trimmed.coverageStart = max(coverageStart, keepFrom)
        trimmed.coverageEnd = min(coverageEnd, keepTo)
        trimmed.days = payload.days?.filter { day in
            guard let start = day.start else { return false }
            return start >= trimmed.coverageStart! && start < trimmed.coverageEnd!
        }
        return trimmed
    }

    /// Days from today's start the watch can read the stats for: through the
    /// day after tomorrow, like `dayOffsets`.
    static let horizonDays = 3

    /// The window `occurrences` keeps when even the stats-free snapshot is
    /// too large: yesterday through tomorrow.
    static func narrowed(_ snapshot: WristSnapshot, now: Date, calendar: Calendar) -> WristSnapshot {
        var copy = snapshot
        let today = calendar.startOfDay(for: now)
        let from = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let to = calendar.date(byAdding: .day, value: 2, to: today) ?? today
        copy.occurrences = snapshot.occurrences.filter { $0.end > from && $0.start < to }
        return copy
    }

    /// Catalog types ordered by recent use (most-used first), ties keeping the
    /// catalog's own order, capped at `maxTypes`. Only catalog entries are
    /// offered — the same source as focus mode's type pills.
    static func rankedTypes(
        events: [Event], templates: [EventTypeTemplate], now: Date, calendar: Calendar
    ) -> [WristType] {
        guard !templates.isEmpty else { return [] }
        let windowStart = calendar.date(byAdding: .day, value: -usageWindowDays, to: now) ?? now
        var counts: [String: Int] = [:]
        for event in events where !event.type.isEmpty {
            // A series is "in use" for as long as it recurs; a one-off counts
            // by its start.
            if event.isRecurringSeries {
                counts[event.type, default: 0] += 1
                continue
            }
            guard let range = event.primaryTimeRange,
                  range.start >= windowStart, range.start <= now else { continue }
            counts[event.type, default: 0] += 1
        }
        return templates.enumerated()
            .sorted { lhs, rhs in
                let l = counts[lhs.element.title] ?? 0
                let r = counts[rhs.element.title] ?? 0
                if l != r { return l > r }
                return lhs.offset < rhs.offset
            }
            .prefix(maxTypes)
            .map { WristType(id: $0.element.id, title: $0.element.title, colorHex: $0.element.colorHex) }
    }

    /// How many names each type sends.
    static let maxTitlesPerType = 6
    /// Names are learned from events that started within this many days.
    static let titleWindowDays = 120
    /// Longer titles are one-off notes, not names worth a tap.
    static let maxTitleLength = 40

    /// Per start-grid type, the names its events were given — not empty and
    /// not just the type's own name — most used first, with when they
    /// usually start and how long they usually last, on which weekdays,
    /// what usually comes right before and after them, and how far into the
    /// day (`WristTitleTimeline`). Spellings that differ only in case or
    /// accents count as one name, shown as most recently written. A use
    /// fades by half every `WristTitleRanking.halfLifeDays`, counted from
    /// the start of today so the figures, and with them the snapshot's
    /// content, hold still through the day. A repeating series counts once,
    /// as a use today, at its first range's time, and teaches no context.
    static func titleHints(
        events: [Event], types: [WristType], now: Date, calendar: Calendar
    ) -> [String: [WristTitleHint]] {
        let wanted = Set(types.map(\.title))
        guard !wanted.isEmpty else { return [:] }
        let today = calendar.startOfDay(for: now)
        let windowStart = calendar.date(byAdding: .day, value: -titleWindowDays, to: today) ?? today

        struct Use {
            var id: String
            var start: Date
            var end: Date
            var weight: Double
            var hasContext: Bool
            var minutes: Double { end.timeIntervalSince(start) / 60 }
        }
        struct Name {
            var title: String
            var latest: Date
            var uses: [Use] = []
        }
        var names: [String: [String: Name]] = [:]
        var timelineItems: [WristTitleTimeline.Item] = []
        func weight(of start: Date) -> Double {
            let ageDays = max(0, today.timeIntervalSince(calendar.startOfDay(for: start)) / 86_400)
            return pow(0.5, ageDays / WristTitleRanking.halfLifeDays)
        }

        // A series counts once per occurrence in the window, through the same
        // per-day expansion the watch's timeline comes from — so its uses age
        // like hand-entered ones, an ended series drops out, and the phone
        // learns the neighbors the watch will see.
        let series = events.filter { $0.isRecurringSeries && !$0.isAllDay && $0.timerStartedAt == nil }
        var seriesUses: [UUID: [Use]] = [:]
        if !series.isEmpty {
            var seen = Set<String>()
            var day = calendar.date(byAdding: .day, value: -1, to: windowStart) ?? windowStart
            while day <= today {
                for occurrence in CalendarLayout.occurrencesForDate(series, date: day, calendar: calendar, now: now)
                where seen.insert(occurrence.id).inserted && occurrence.range.end > occurrence.range.start {
                    let event = occurrence.event
                    let range = occurrence.range
                    timelineItems.append(WristTitleTimeline.Item(
                        id: occurrence.id, start: range.start, end: range.end,
                        title: event.title.trimmingCharacters(in: .whitespacesAndNewlines), type: event.type
                    ))
                    guard range.start >= windowStart, range.start <= now else { continue }
                    seriesUses[event.id, default: []].append(Use(
                        id: occurrence.id, start: range.start, end: range.end,
                        weight: weight(of: range.start), hasContext: true
                    ))
                }
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
        }

        for event in events where !event.isAllDay && event.timerStartedAt == nil {
            let title = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
            var uses: [Use] = []
            if event.isRecurringSeries {
                uses = seriesUses[event.id] ?? []
            } else {
                for (index, range) in event.timeRanges.enumerated()
                where range.end > range.start && range.start >= windowStart.addingTimeInterval(-86_400) {
                    let id = "\(event.id.uuidString)#\(index)"
                    timelineItems.append(WristTitleTimeline.Item(
                        id: id, start: range.start, end: range.end, title: title, type: event.type
                    ))
                    guard range.start >= windowStart, range.start <= now else { continue }
                    uses.append(Use(
                        id: id, start: range.start, end: range.end,
                        weight: weight(of: range.start), hasContext: true
                    ))
                }
            }
            guard wanted.contains(event.type), !title.isEmpty, title.count <= maxTitleLength,
                  WristTitleTable.fold(title) != WristTitleTable.fold(event.type),
                  let newest = uses.map(\.start).max() else { continue }
            let key = WristTitleTable.fold(title)
            var name = names[event.type]?[key] ?? Name(title: title, latest: newest)
            if newest > name.latest {
                name.title = title
                name.latest = newest
            }
            name.uses += uses
            names[event.type, default: [:]][key] = name
        }

        // The names that make the cut, then their context: neighbors are
        // named through the table those very names form.
        // The table's order must be the order the hints are sent in — the
        // watch rebuilds the table from them, and neighbors are indices into
        // it — so the kept names are ordered by the weight as sent.
        func total(_ name: Name) -> Double { name.uses.reduce(0) { $0 + $1.weight } }
        let chosen: [String: [Name]] = names.mapValues { byKey -> [Name] in
            let ranked: [Name] = byKey.values.sorted { lhs, rhs in
                let l = total(lhs), r = total(rhs)
                return l != r ? l > r : lhs.title < rhs.title
            }
            return Array(ranked.prefix(maxTitlesPerType)).sorted { lhs, rhs in
                let l = sentWeight(total(lhs)), r = sentWeight(total(rhs))
                return l != r ? l > r : lhs.title < rhs.title
            }
        }
        let table = WristTitleTable(
            typeOrder: types.map(\.title),
            hints: chosen.mapValues { $0.map { WristTitleHint(title: $0.title, weight: 0, startMinute: 0, concentration: 0, minutes: 0) } }
        )
        let timeline = WristTitleTimeline(timelineItems)

        func learned(_ use: Use) -> LearnedUse {
            let context: WristTitleContext? = use.hasContext
                ? timeline.context(start: use.start, end: use.end, excluding: use.id, table: table, calendar: calendar)
                : nil
            return LearnedUse(start: use.start, minutes: use.minutes, weight: use.weight, context: context)
        }
        return chosen.mapValues { list -> [WristTitleHint] in
            let hints: [WristTitleHint] = list.map { hint(for: $0.title, uses: $0.uses.map(learned), calendar: calendar) }
            return hints.sorted { $0.weight != $1.weight ? $0.weight > $1.weight : $0.title < $1.title }
        }
    }

    struct LearnedUse {
        var start: Date
        var minutes: Double
        var weight: Double
        var context: WristTitleContext?
    }

    /// A name's recency weight as it goes on the wire.
    static func sentWeight(_ total: Double) -> Double {
        max(0.1, (total * 10).rounded() / 10)
    }

    /// Pairs kept per neighbor list.
    static let maxNeighbors = 3

    /// One name's figures from its uses.
    static func hint(for title: String, uses: [LearnedUse], calendar: Calendar) -> WristTitleHint {
        let weight = uses.reduce(0) { $0 + $1.weight }
        var x = 0.0, y = 0.0
        for use in uses {
            let parts = calendar.dateComponents([.hour, .minute], from: use.start)
            let angle = Double((parts.hour ?? 0) * 60 + (parts.minute ?? 0)) / 1440 * 2 * .pi
            x += use.weight * cos(angle)
            y += use.weight * sin(angle)
        }
        var meanAngle = atan2(y, x)
        if meanAngle < 0 { meanAngle += 2 * .pi }

        let withContext = uses.compactMap { use in use.context.map { (use.weight, $0) } }
        var weekdays: [Int]?
        var previous: [Int]?
        var next: [Int]?
        var intoDay: Int?
        var intoDaySpread: Int?
        if !withContext.isEmpty {
            var days = [Double](repeating: 0, count: 7)
            var before: [Int: Double] = [:], after: [Int: Double] = [:]
            var beforeTotal = 0.0, afterTotal = 0.0
            var into: [(Double, Double)] = []
            for (w, context) in withContext {
                if let day = context.weekday, (1...7).contains(day) { days[day - 1] += w }
                if let value = WristTitleContext.learned(context.previous) { before[value, default: 0] += w }
                if context.previous != nil { beforeTotal += w }
                if let value = WristTitleContext.learned(context.next) { after[value, default: 0] += w }
                if context.next != nil { afterTotal += w }
                if let minutes = context.minutesIntoDay { into.append((Double(minutes), w)) }
            }
            let dayTotal = days.reduce(0, +)
            if dayTotal > 0 { weekdays = days.map { Int(($0 / dayTotal * 100).rounded()) } }
            previous = pairs(before, total: beforeTotal)
            next = pairs(after, total: afterTotal)
            if let median = weightedMedian(into) {
                intoDay = Int(median.rounded())
                intoDaySpread = weightedMedian(into.map { (abs($0.0 - median), $0.1) }).map { Int($0.rounded()) }
            }
        }
        return WristTitleHint(
            title: title,
            weight: sentWeight(weight),
            startMinute: Int((meanAngle / (2 * .pi) * 1440).rounded()) % 1440,
            concentration: weight > 0 ? Int((hypot(x, y) / weight * 100).rounded()) : 0,
            minutes: max(1, Int((weightedMedian(uses.map { ($0.minutes, $0.weight) }) ?? 60).rounded())),
            weekdays: weekdays, previous: previous, next: next,
            intoDay: intoDay, intoDaySpread: intoDaySpread
        )
    }

    /// The commonest values with their percent of `total` (which also
    /// counts neighbors the table could not name), flattened.
    private static func pairs(_ counts: [Int: Double], total: Double) -> [Int]? {
        guard total > 0 else { return nil }
        let kept = counts
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(maxNeighbors)
            .map { (key: $0.key, pct: Int(($0.value / total * 100).rounded())) }
            .filter { $0.pct > 0 }
        return kept.flatMap { [$0.key, $0.pct] }
    }

    private static func weightedMedian(_ values: [(Double, Double)]) -> Double? {
        let sorted = values.sorted { $0.0 < $1.0 }
        let total = sorted.reduce(0) { $0 + $1.1 }
        guard total > 0 else { return sorted.first?.0 }
        var running = 0.0
        return sorted.first { value in
            running += value.1
            return running >= total / 2
        }?.0 ?? sorted.last?.0
    }

    /// Timed occurrences for yesterday through the day after tomorrow,
    /// through the same per-day expansion the canvas and focus mode use
    /// (`occurrencesForDate` yields no all-day items). A running phone-side
    /// timer projects open-ended: its stored end is the moment it was last
    /// looked at, which would read as "over" on the wrist within seconds.
    static func occurrences(
        events: [Event], now: Date, calendar: Calendar, colorHex: (String) -> String
    ) -> [WristOccurrence] {
        var seen = Set<String>()
        var result: [WristOccurrence] = []
        var rank: [UUID: Int] = [:]
        for (index, event) in events.enumerated() where rank[event.id] == nil {
            rank[event.id] = index
        }
        for offset in dayOffsets {
            guard let date = calendar.date(byAdding: .day, value: offset, to: now) else { continue }
            for occurrence in CalendarLayout.occurrencesForDate(events, date: date, calendar: calendar, now: now) {
                let event = occurrence.event
                guard seen.insert(occurrence.id).inserted else { continue }
                let title = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let isTimer = event.timerStartedAt != nil
                result.append(
                    WristOccurrence(
                        id: occurrence.id,
                        eventID: event.id,
                        title: title.isEmpty ? event.type : title,
                        type: event.type,
                        colorHex: colorHex(event.type),
                        start: occurrence.range.start,
                        end: isTimer ? .distantFuture : occurrence.range.end,
                        isInterrupt: event.displayKind == .interrupt
                            && event.interruptRelation?.state == .embedded,
                        quickActionsEnabled: !isTimer && focusQuickActionAllowedForEvent(event),
                        isOpenEnded: isTimer,
                        createdAt: event.createdAt,
                        seriesID: event.recurrenceParentId,
                        interruptParentID: event.interruptRelation?.state == .embedded
                            ? event.interruptRelation?.parentEventID : nil
                    )
                )
            }
        }
        // Store order, then start: what focus mode's "first" reads.
        let ordered = result.enumerated().sorted { a, b in
            let ra = rank[a.element.eventID] ?? .max, rb = rank[b.element.eventID] ?? .max
            if ra != rb { return ra < rb }
            if a.element.start != b.element.start { return a.element.start < b.element.start }
            return a.offset < b.offset
        }.map(\.element)
        return withCreationStamps(ordered, now: now, calendar: calendar)
    }

    /// Keeps the creation stamp only where it can decide something, so a
    /// dense day still fits the transfer: it orders blocks that start
    /// together on a day page (the phone clips a block to the day, so
    /// everything running in from the night before starts together too),
    /// and an interrupt family's stamp is its members'. To the millisecond,
    /// all the phone compares.
    static func withCreationStamps(_ occurrences: [WristOccurrence], now: Date, calendar: Calendar) -> [WristOccurrence] {
        var result = occurrences
        let families = Set(result.compactMap(\.interruptParentID))
        func family(_ o: WristOccurrence) -> UUID? {
            o.interruptParentID ?? (families.contains(o.anchorID) ? o.anchorID : nil)
        }
        var stamped = Set<Int>()
        for offset in dayOffsets {
            guard let date = calendar.date(byAdding: .day, value: offset, to: now) else { continue }
            let dayStart = calendar.startOfDay(for: date)
            let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
            var byStart: [Date: [Int]] = [:]
            for (i, o) in result.enumerated() where o.start < dayEnd && o.end > dayStart {
                byStart[max(o.start, dayStart), default: []].append(i)
            }
            for group in byStart.values where group.count > 1 { stamped.formUnion(group) }
        }
        let tiedFamilies = Set(stamped.compactMap { family(result[$0]) })
        for i in result.indices {
            let keepsStamp = stamped.contains(i) || family(result[i]).map(tiedFamilies.contains) == true
            result[i].createdAt = keepsStamp
                ? result[i].createdAt.map { Date(timeIntervalSince1970: ($0.timeIntervalSince1970 * 1000).rounded() / 1000) }
                : nil
        }
        return result
    }
}
