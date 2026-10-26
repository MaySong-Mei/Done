import Foundation

/// The span a "Time by Category" widget sums, chosen per widget instance.
///
/// The ranges are the Analysis tab's own (`AnalysisViewModel.dateRange` calls
/// `CategoryStats.range` with its offset), so a widget set to a period and the
/// tab showing the same period at offset 0 sum the same days.
nonisolated enum CategoryStatsPeriod: String, CaseIterable, Codable, Hashable {
    case today
    case week
    case month
}

/// What a "Time by Category" widget's percents are of, chosen per widget
/// instance.
nonisolated enum CategoryStatsBasis: String, CaseIterable, Codable, Hashable {
    /// The time logged in the period: the bar is the logged hours, split by
    /// category.
    case logged
    /// The time elapsed in the period: the bar is the elapsed span, filled
    /// by category like a loading bar, and what nothing was logged in is
    /// "Unlogged". 100% less the unlogged share is the Analysis tab's record
    /// rate (`AnalysisViewModel.recordRate`).
    case elapsed
}

/// One widget instance's configuration, as the reading side needs it. The
/// defaults are the Edit Widget sheet's.
nonisolated struct CategoryStatsOptions: Equatable {
    var period: CategoryStatsPeriod = .week
    var basis: CategoryStatsBasis = .logged
    /// Leave out the categories the user hides from the Me tab
    /// (`CategoryStatsPayload.backgroundCategories`). The logged basis only:
    /// the elapsed basis's bar is the whole span, background included.
    var excludesBackground = false
}

/// The Me page's "background types" setting (`AppSettingsKeys.meBackgroundTypes`)
/// is one comma-separated string. Parsing lives here, out of the view, so a
/// body pass splits it ONCE: the resulting set feeds a predicate that is
/// called per event (inside `calendarProjectedTypeHours`), per heatmap cell,
/// and per stacked-bar segment, and the old computed-property form re-split
/// the raw string on every one of those calls (gh#214).
///
/// In the file both targets compile: the category-stats widget leaves out
/// the same categories by the same rule, from the set the app parsed here
/// and wrote into the payload.
nonisolated enum MeBackgroundTypes {
    static func parse(_ raw: String) -> Set<String> {
        Set(raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        )
    }

    /// Matching is case-insensitive on the type name, exactly as the
    /// computed-property form was.
    static func contains(_ type: String, in parsed: Set<String>) -> Bool {
        parsed.contains(type.lowercased())
    }
}

/// What the app writes to the App Group for the category-stats widget.
///
/// Not hours: the elementary slices of the Analysis tab's per-day overlap
/// sweep (`Event.overlapSlices`), unclamped, each with the categories that
/// cover it and how many of the covering occurrences belong to each. A slice
/// lies wholly inside or wholly outside every interval the sweep saw, so
/// cutting the slices at an instant and summing them is exactly the sweep run
/// with that instant as "now" — which is how a widget entry rendered hours
/// after the write still agrees with the tab (see `CategoryStats.hours`).
///
/// Every field is optional for the reason `SharedEventSnapshot`'s new fields
/// are: the blob outlives the binary that wrote it, in both directions. A
/// payload the reader cannot use reads as no payload, never as zero hours.
nonisolated struct CategoryStatsPayload: Codable, Hashable {
    static let currentVersion = 1

    var version: Int?
    /// When the payload was computed. Informational: it is left out of the
    /// app's change detection (`withoutWriteStamp`), or every sync would
    /// count as a change.
    var writtenAt: Date?
    /// The slices cover `[coverageStart, coverageEnd)`, as whole civil days of
    /// `calendar`. A period starting earlier, or an instant at or past the
    /// end, cannot be answered from this payload.
    var coverageStart: Date?
    var coverageEnd: Date?
    /// The calendar the days were cut in. The widget cuts its periods in the
    /// same one, so its days and the payload's line up even if the device
    /// has changed zones since the write.
    var calendar: CalendarFrame?
    var categories: [Category]?
    var days: [Day]?
    /// The categories the user hides from the Me tab, as `MeBackgroundTypes`
    /// parsed them, sorted. Not part of the build: stamped at each write, like
    /// the colours, so changing the setting is a payload change. `nil` in a
    /// payload from before the widget could leave them out.
    var backgroundCategories: [String]?

    struct CalendarFrame: Codable, Hashable {
        var identifier: String?
        var timeZone: String?
        var firstWeekday: Int?
        var minimumDaysInFirstWeek: Int?
    }

    struct Category: Codable, Hashable {
        /// The Analysis tab's bucket name: the event type, "Other" when empty.
        var name: String?
        var colorHex: String?
    }

    /// One civil day's slices, keyed by the day's start.
    struct Day: Codable, Hashable {
        var start: Date?
        var slices: [Slice]?

        enum CodingKeys: String, CodingKey {
            case start = "d"
            case slices = "s"
        }
    }

    /// `[start, end)`, covered by `n` occurrences, `counts[i]` of which belong
    /// to `categories[categoryIndices[i]]`: that category is credited
    /// `counts[i] / n` of the slice.
    struct Slice: Codable, Hashable {
        var start: Date?
        var end: Date?
        var n: Int?
        var categoryIndices: [Int]?
        var counts: [Int]?

        enum CodingKeys: String, CodingKey {
            case start = "s"
            case end = "e"
            case n
            case categoryIndices = "c"
            case counts = "k"
        }
    }

    /// The payload as the app's write guard compares it: everything but the
    /// write time.
    var withoutWriteStamp: CategoryStatsPayload {
        var copy = self
        copy.writtenAt = nil
        return copy
    }

    /// The calendar the payload was cut in, rebuilt; `fallback` for whatever
    /// the payload does not say.
    func resolvedCalendar(fallback: Calendar = .current) -> Calendar {
        guard let frame = calendar else { return fallback }
        var result = fallback
        if let identifier = frame.identifier,
           let rebuilt = NSCalendar(calendarIdentifier: NSCalendar.Identifier(rawValue: identifier)) {
            result = rebuilt as Calendar
        }
        if let zone = frame.timeZone.flatMap(TimeZone.init(identifier:)) {
            result.timeZone = zone
        }
        if let first = frame.firstWeekday, (1...7).contains(first) {
            result.firstWeekday = first
        }
        if let minimum = frame.minimumDaysInFirstWeek, (1...7).contains(minimum) {
            result.minimumDaysInFirstWeek = minimum
        }
        return result
    }

    static func frame(of calendar: Calendar) -> CalendarFrame {
        CalendarFrame(
            identifier: (calendar as NSCalendar).calendarIdentifier.rawValue,
            timeZone: calendar.timeZone.identifier,
            firstWeekday: calendar.firstWeekday,
            minimumDaysInFirstWeek: calendar.minimumDaysInFirstWeek
        )
    }
}

/// One category's hours in a period.
nonisolated struct CategoryHours: Equatable {
    var name: String
    var colorHex: String?
    var hours: Double
}

nonisolated enum CategoryStatsStatus: Equatable {
    /// No payload, or one this binary cannot read.
    case noData
    /// The payload does not reach the period or the instant asked about.
    case stale
    /// Readable, and nothing was logged in the period up to the instant.
    case empty
    case ok
}

/// One period's figures at one instant: what a widget entry carries.
nonisolated struct CategoryStatsSummary: Equatable {
    var period: CategoryStatsPeriod
    var basis: CategoryStatsBasis = .logged
    var status: CategoryStatsStatus
    /// Categories with time in the period, most hours first.
    var categories: [CategoryHours]
    /// The categories' hours together.
    var totalHours: Double
    /// The period's elapsed hours at the instant, in the elapsed basis: the
    /// span the whole bar stands for. Zero in the logged basis.
    var elapsedHours: Double = 0

    /// The elapsed hours nothing was logged in; `nil` in the logged basis,
    /// which has no such row.
    var unloggedHours: Double? {
        basis == .elapsed ? max(0, elapsedHours - totalHours) : nil
    }
}

/// One line of a widget's list, and one segment of its bar.
nonisolated struct CategoryStatsRow: Equatable {
    enum Kind: Equatable {
        /// A real category, by its rank among the period's categories.
        case category(rank: Int)
        /// The categories that did not get a row of their own.
        case remainder(count: Int)
        /// The elapsed basis's elapsed time with nothing logged in it: always
        /// the last row.
        case unlogged
    }

    var kind: Kind
    /// The category's name; empty for the remainder and the unlogged row,
    /// which are labelled by `LFormat.statsRemainder` and `.statsUnlogged`
    /// so neither can ever read as a category.
    var name: String
    var colorHex: String?
    var hours: Double
    /// `hours` over the bar's whole: the logged total, or in the elapsed
    /// basis the elapsed span.
    var share: Double
    /// Whole percent, rounded so the rows sum to exactly 100.
    var percent: Int

    var isRemainder: Bool {
        if case .remainder = kind { return true }
        return false
    }

    var isUnlogged: Bool { kind == .unlogged }

    /// "42%", or "<1%" for time that rounds to nothing.
    var percentText: String {
        percent == 0 && hours > 0 ? "<1%" : "\(percent)%"
    }
}

/// Pure arithmetic for the category-stats widget. Lives in the file both
/// targets compile so `DoneTests` can test it; the widget only draws.
nonisolated enum CategoryStats {

    // MARK: - Periods

    /// `[start, end)` of `period` around `date`, moved by `offset` periods.
    /// The Analysis tab's ranges (`AnalysisViewModel.dateRange`): the week
    /// from the calendar's own week start, the month from its first day.
    static func range(
        of period: CategoryStatsPeriod, containing date: Date, offset: Int = 0, calendar: Calendar
    ) -> (start: Date, end: Date) {
        let today = calendar.startOfDay(for: date)
        switch period {
        case .today:
            let start = calendar.date(byAdding: .day, value: offset, to: today) ?? today
            let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
            return (start, end)
        case .week:
            let weekStart = calendar.date(
                from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: today)
            ) ?? today
            let start = calendar.date(byAdding: .weekOfYear, value: offset, to: weekStart) ?? weekStart
            let end = calendar.date(byAdding: .day, value: 7, to: start) ?? start.addingTimeInterval(7 * 86_400)
            return (start, end)
        case .month:
            let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: today)) ?? today
            let start = calendar.date(byAdding: .month, value: offset, to: monthStart) ?? monthStart
            let end = calendar.date(byAdding: .month, value: 1, to: start) ?? start.addingTimeInterval(31 * 86_400)
            return (start, end)
        }
    }

    /// The days of `[start, end)` the way the Analysis tab walks them
    /// (`AnalysisViewModel.daysInRange`): from `start`, a calendar day at a
    /// time. Each is a day by its `startOfDay`.
    static func days(from start: Date, to end: Date, calendar: Calendar) -> [Date] {
        var days: [Date] = []
        var current = start
        while current < end {
            days.append(current)
            guard let next = calendar.date(byAdding: .day, value: 1, to: current), next > current else { break }
            current = next
        }
        return days
    }

    // MARK: - Reading the payload

    /// The elapsed-clamp rule: `asOf` clamped into `[windowStart, windowEnd]`,
    /// the instant up to which a window's time counts as spent.
    /// `Event.elapsedWindowCut` is this function, so the widget and the
    /// Analysis tab cannot cut a period differently.
    static func elapsedCut(windowStart: Date, windowEnd: Date, asOf: Date) -> Date {
        min(max(asOf, windowStart), windowEnd)
    }

    /// Hours of `period` around `asOf` elapsed by `asOf`: the denominator of
    /// the Analysis tab's record rate (`AnalysisViewModel.recordRate`).
    static func elapsedHours(of period: CategoryStatsPeriod, asOf: Date, calendar: Calendar) -> Double {
        elapsedHours(in: range(of: period, containing: asOf, calendar: calendar), asOf: asOf)
    }

    /// `elapsedHours(of:)` for any span of whole days, not only a period's.
    static func elapsedHours(in span: (start: Date, end: Date), asOf: Date) -> Double {
        elapsedCut(windowStart: span.start, windowEnd: span.end, asOf: asOf).timeIntervalSince(span.start) / 3600
    }

    /// Hours per category name in `period`'s days around `asOf`, counting
    /// only time before `asOf` — the Analysis tab's elapsed-clamp. Days the
    /// payload does not cover contribute nothing; `status` is what says
    /// whether that makes the answer wrong.
    ///
    /// `excludingBackground` drops the payload's background categories, and
    /// only them: their part of a slice they split with others is left out,
    /// not handed to the others — what the Me tab's `activeWeekHours` does.
    static func hours(
        in payload: CategoryStatsPayload, period: CategoryStatsPeriod, asOf: Date, excludingBackground: Bool = false
    ) -> [String: Double] {
        let range = range(of: period, containing: asOf, calendar: payload.resolvedCalendar())
        return hours(in: payload, span: range, asOf: asOf, excludingBackground: excludingBackground)
    }

    /// `hours(in:period:)` for any span of whole days of the payload's
    /// calendar, not only a period's.
    static func hours(
        in payload: CategoryStatsPayload, span range: (start: Date, end: Date), asOf: Date,
        excludingBackground: Bool = false
    ) -> [String: Double] {
        let calendar = payload.resolvedCalendar()
        var buckets: [Date: CategoryStatsPayload.Day] = [:]
        for day in payload.days ?? [] {
            guard let start = day.start, buckets[start] == nil else { continue }
            buckets[start] = day
        }
        let categories = payload.categories ?? []

        var byIndex: [Int: Double] = [:]
        for day in days(from: range.start, to: range.end, calendar: calendar) {
            guard let bucket = buckets[calendar.startOfDay(for: day)] else { continue }
            for slice in bucket.slices ?? [] {
                guard let start = slice.start, let end = slice.end, let n = slice.n, n > 0 else { continue }
                let cut = min(end, asOf)
                guard cut > start else { continue }
                let sliceHours = cut.timeIntervalSince(start) / 3600 / Double(n)
                for (index, count) in zip(slice.categoryIndices ?? [], slice.counts ?? [])
                where categories.indices.contains(index) && count > 0 {
                    byIndex[index, default: 0] += sliceHours * Double(count)
                }
            }
        }

        let background = Set(excludingBackground ? payload.backgroundCategories ?? [] : [])
        var hours: [String: Double] = [:]
        for (index, value) in byIndex {
            guard let name = categories[index].name, !MeBackgroundTypes.contains(name, in: background) else { continue }
            hours[name, default: 0] += value
        }
        return hours
    }

    /// Whether `payload` can answer `period` at `asOf`. In the elapsed basis
    /// anything elapsed is something to show, logged or not; in the logged
    /// basis only logged hours are.
    static func status(
        of payload: CategoryStatsPayload?, period: CategoryStatsPeriod, asOf: Date,
        basis: CategoryStatsBasis = .logged, excludingBackground: Bool = false
    ) -> CategoryStatsStatus {
        guard let payload else { return .noData }
        let range = range(of: period, containing: asOf, calendar: payload.resolvedCalendar())
        return status(of: payload, span: range, asOf: asOf, basis: basis, excludingBackground: excludingBackground)
    }

    /// `status(of:period:)` for any span of whole days of the payload's
    /// calendar, not only a period's.
    static func status(
        of payload: CategoryStatsPayload?, span range: (start: Date, end: Date), asOf: Date,
        basis: CategoryStatsBasis = .logged, excludingBackground: Bool = false
    ) -> CategoryStatsStatus {
        // A newer format is unreadable here by definition, whatever its
        // fields happen to decode to.
        guard let payload, (payload.version ?? 0) <= CategoryStatsPayload.currentVersion,
              let coverageStart = payload.coverageStart, let coverageEnd = payload.coverageEnd,
              coverageStart < coverageEnd, payload.days != nil, payload.categories != nil
        else { return .noData }
        if asOf >= coverageEnd || range.start < coverageStart { return .stale }
        switch basis {
        case .elapsed:
            return elapsedHours(in: range, asOf: asOf) > 0 ? .ok : .empty
        case .logged:
            // A payload from a build before the option carries no list: it
            // cannot say which hours to leave out until the app writes again.
            if excludingBackground, payload.backgroundCategories == nil { return .stale }
            let total = hours(in: payload, span: range, asOf: asOf, excludingBackground: excludingBackground)
                .values.reduce(0, +)
            return total > 0 ? .ok : .empty
        }
    }

    /// Everything a widget entry needs for `period` at `asOf`, in `basis`.
    /// `excludingBackground` applies to the logged basis only (see
    /// `CategoryStatsOptions.excludesBackground`).
    static func summary(
        of payload: CategoryStatsPayload?, period: CategoryStatsPeriod, asOf: Date,
        basis: CategoryStatsBasis = .logged, excludingBackground: Bool = false
    ) -> CategoryStatsSummary {
        let excluding = excludingBackground && basis == .logged
        let status = status(of: payload, period: period, asOf: asOf, basis: basis, excludingBackground: excluding)
        guard status == .ok, let payload else {
            return CategoryStatsSummary(period: period, basis: basis, status: status, categories: [], totalHours: 0)
        }
        let ranked = ranked(hours(in: payload, period: period, asOf: asOf, excludingBackground: excluding),
                            colors: colors(in: payload))
        return CategoryStatsSummary(
            period: period, basis: basis, status: status, categories: ranked,
            totalHours: ranked.reduce(0) { $0 + $1.hours },
            elapsedHours: basis == .elapsed
                ? elapsedHours(of: period, asOf: asOf, calendar: payload.resolvedCalendar()) : 0
        )
    }

    static func summary(
        of payload: CategoryStatsPayload?, options: CategoryStatsOptions, asOf: Date
    ) -> CategoryStatsSummary {
        summary(of: payload, period: options.period, asOf: asOf, basis: options.basis,
                excludingBackground: options.excludesBackground)
    }

    /// Each category name's colour, the first the payload gives it.
    static func colors(in payload: CategoryStatsPayload) -> [String: String] {
        var colors: [String: String] = [:]
        for category in payload.categories ?? [] {
            if let name = category.name, colors[name] == nil, let hex = category.colorHex { colors[name] = hex }
        }
        return colors
    }

    /// Categories with time, most first; ties by name so the order is stable.
    static func ranked(_ hours: [String: Double], colors: [String: String] = [:]) -> [CategoryHours] {
        hours
            .filter { $0.value > 0 && $0.value.isFinite }
            .map { CategoryHours(name: $0.key, colorHex: colors[$0.key], hours: $0.value) }
            .sorted { $0.hours == $1.hours ? $0.name < $1.name : $0.hours > $1.hours }
    }

    // MARK: - Display

    /// The rows a widget draws when it has room for `maxRows`: every category
    /// when they fit, otherwise the first `maxRows - 1` and one remainder row
    /// for the rest — or, without `includeRemainder` (a face that lists only
    /// the leaders), the first `maxRows` and nothing for the rest.
    ///
    /// With `unlogged` (the elapsed basis), the shares are of the logged and
    /// unlogged hours together — the elapsed span — and the unlogged row is
    /// the last of the `maxRows`, there even when nothing was logged.
    ///
    /// When the rows account for all the time, their percents are rounded
    /// together and sum to exactly 100. When a face leaves categories out
    /// (`includeRemainder` false, or no room for the remainder row), the rows
    /// drawn cannot sum to 100, and each is its own share rounded to the
    /// nearest point: rounding them with the hidden rest would hand a row a
    /// point the hidden categories earned.
    static func breakdown(
        _ categories: [CategoryHours], maxRows: Int, includeRemainder: Bool = true, unlogged: Double? = nil
    ) -> [CategoryStatsRow] {
        let shown = categories.filter { $0.hours > 0 && $0.hours.isFinite }
        let unloggedHours = unlogged.map { $0.isFinite ? max(0, $0) : 0 }
        guard maxRows > 0, !shown.isEmpty || (unloggedHours ?? 0) > 0 else { return [] }
        let total = shown.reduce(0) { $0 + $1.hours } + (unloggedHours ?? 0)
        let slots = unloggedHours == nil ? maxRows : maxRows - 1
        let ownRows = shown.count <= slots || !includeRemainder || slots <= 1
            ? min(shown.count, slots)
            : slots - 1

        var rows: [CategoryStatsRow] = []
        for (rank, category) in shown.prefix(ownRows).enumerated() {
            rows.append(CategoryStatsRow(
                kind: .category(rank: rank), name: category.name, colorHex: category.colorHex,
                hours: category.hours, share: category.hours / total, percent: 0
            ))
        }
        let rest = shown.dropFirst(ownRows)
        let restHours = rest.reduce(0) { $0 + $1.hours }
        let hidesRest = !rest.isEmpty && !(includeRemainder && slots > 1)
        let parts = rows.map(\.hours) + (rest.isEmpty ? [] : [restHours]) + (unloggedHours.map { [$0] } ?? [])
        let rounded = hidesRest ? parts.map { Int(($0 / total * 100).rounded()) } : percents(parts)
        for index in rows.indices { rows[index].percent = rounded[index] }
        if !hidesRest, !rest.isEmpty {
            rows.append(CategoryStatsRow(
                kind: .remainder(count: rest.count), name: "", colorHex: nil,
                hours: restHours, share: restHours / total, percent: rounded[rows.count]
            ))
        }
        if let unloggedHours, let last = rounded.last {
            rows.append(CategoryStatsRow(
                kind: .unlogged, name: "", colorHex: nil,
                hours: unloggedHours, share: unloggedHours / total, percent: last
            ))
        }
        return rows
    }

    /// Whole percents of `values`' total that sum to exactly 100 (largest
    /// remainder: round everything down, then give the missing points to the
    /// largest fractions, ties to the earlier value). All zeros when there is
    /// nothing to share.
    static func percents(_ values: [Double]) -> [Int] {
        let clean = values.map { $0.isFinite ? max(0, $0) : 0 }
        let total = clean.reduce(0, +)
        guard total > 0 else { return clean.map { _ in 0 } }
        let exact = clean.map { $0 / total * 100 }
        var result = exact.map { Int($0.rounded(.down)) }
        var missing = 100 - result.reduce(0, +)
        let byFraction = exact.indices.sorted {
            let a = exact[$0] - Double(result[$0]), b = exact[$1] - Double(result[$1])
            return a == b ? $0 < $1 : a > b
        }
        var cursor = 0
        while missing > 0, !byFraction.isEmpty {
            result[byFraction[cursor % byFraction.count]] += 1
            missing -= 1
            cursor += 1
        }
        return result
    }
}

extension SharedWidgetData {
    /// The category-stats payload (`CategoryStatsPayload`), beside the
    /// occurrence snapshots and written with them (`write(events:...)`).
    static let categoryStatsKey = "widgetCategoryStats"

    /// `nil` when there is no payload or it does not decode.
    static func readCategoryStats() -> CategoryStatsPayload? {
        guard let defaults = sharedDefaults,
              let data = defaults.data(forKey: categoryStatsKey) else { return nil }
        return try? JSONDecoder().decode(CategoryStatsPayload.self, from: data)
    }
}
