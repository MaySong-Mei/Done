import Foundation

/// The span a "Time by Category" widget sums, chosen per widget instance.
///
/// The ranges are the Analysis tab's own (`AnalysisViewModel.dateRange` calls
/// `CategoryStats.range` with its offset), so a widget set to a period and the
/// tab showing the same period at offset 0 sum the same days.
enum CategoryStatsPeriod: String, CaseIterable, Codable, Hashable {
    case today
    case week
    case month
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
struct CategoryStatsPayload: Codable, Hashable {
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
struct CategoryHours: Equatable {
    var name: String
    var colorHex: String?
    var hours: Double
}

enum CategoryStatsStatus: Equatable {
    /// No payload, or one this binary cannot read.
    case noData
    /// The payload does not reach the period or the instant asked about.
    case stale
    /// Readable, and nothing was logged in the period up to the instant.
    case empty
    case ok
}

/// One period's figures at one instant: what a widget entry carries.
struct CategoryStatsSummary: Equatable {
    var period: CategoryStatsPeriod
    var status: CategoryStatsStatus
    /// Categories with time in the period, most hours first.
    var categories: [CategoryHours]
    var totalHours: Double
}

/// One line of a widget's list, and one segment of its bar.
struct CategoryStatsRow: Equatable {
    enum Kind: Equatable {
        /// A real category, by its rank among the period's categories.
        case category(rank: Int)
        /// The categories that did not get a row of their own.
        case remainder(count: Int)
    }

    var kind: Kind
    /// The category's name; empty for the remainder, which is labelled by
    /// `LFormat.categoryRemainder` so it can never read as a category.
    var name: String
    var colorHex: String?
    var hours: Double
    /// `hours` over the period's total, for the bar.
    var share: Double
    /// Whole percent, rounded so the rows sum to exactly 100.
    var percent: Int

    var isRemainder: Bool {
        if case .remainder = kind { return true }
        return false
    }

    /// "42%", or "<1%" for time that rounds to nothing.
    var percentText: String {
        percent == 0 && hours > 0 ? "<1%" : "\(percent)%"
    }
}

/// Pure arithmetic for the category-stats widget. Lives in the file both
/// targets compile so `DoneTests` can test it; the widget only draws.
enum CategoryStats {

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

    /// Hours per category name in `period`'s days around `asOf`, counting
    /// only time before `asOf` — the Analysis tab's elapsed-clamp. Days the
    /// payload does not cover contribute nothing; `status` is what says
    /// whether that makes the answer wrong.
    static func hours(
        in payload: CategoryStatsPayload, period: CategoryStatsPeriod, asOf: Date
    ) -> [String: Double] {
        let calendar = payload.resolvedCalendar()
        let range = range(of: period, containing: asOf, calendar: calendar)
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

        var hours: [String: Double] = [:]
        for (index, value) in byIndex {
            guard let name = categories[index].name else { continue }
            hours[name, default: 0] += value
        }
        return hours
    }

    /// Whether `payload` can answer `period` at `asOf`.
    static func status(
        of payload: CategoryStatsPayload?, period: CategoryStatsPeriod, asOf: Date
    ) -> CategoryStatsStatus {
        // A newer format is unreadable here by definition, whatever its
        // fields happen to decode to.
        guard let payload, (payload.version ?? 0) <= CategoryStatsPayload.currentVersion,
              let coverageStart = payload.coverageStart, let coverageEnd = payload.coverageEnd,
              coverageStart < coverageEnd, payload.days != nil, payload.categories != nil
        else { return .noData }
        let range = range(of: period, containing: asOf, calendar: payload.resolvedCalendar())
        if asOf >= coverageEnd || range.start < coverageStart { return .stale }
        let total = hours(in: payload, period: period, asOf: asOf).values.reduce(0, +)
        return total > 0 ? .ok : .empty
    }

    /// Everything a widget entry needs for `period` at `asOf`.
    static func summary(
        of payload: CategoryStatsPayload?, period: CategoryStatsPeriod, asOf: Date
    ) -> CategoryStatsSummary {
        let status = status(of: payload, period: period, asOf: asOf)
        guard status == .ok, let payload else {
            return CategoryStatsSummary(period: period, status: status, categories: [], totalHours: 0)
        }
        var colors: [String: String] = [:]
        for category in payload.categories ?? [] {
            if let name = category.name, colors[name] == nil, let hex = category.colorHex { colors[name] = hex }
        }
        let ranked = ranked(hours(in: payload, period: period, asOf: asOf), colors: colors)
        return CategoryStatsSummary(
            period: period, status: status, categories: ranked,
            totalHours: ranked.reduce(0) { $0 + $1.hours }
        )
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
    /// Percents are rounded together with whatever is left out, so the rows
    /// drawn sum to exactly 100 whenever they account for all the time.
    static func breakdown(
        _ categories: [CategoryHours], maxRows: Int, includeRemainder: Bool = true
    ) -> [CategoryStatsRow] {
        let shown = categories.filter { $0.hours > 0 && $0.hours.isFinite }
        guard maxRows > 0, !shown.isEmpty else { return [] }
        let total = shown.reduce(0) { $0 + $1.hours }
        let ownRows = shown.count <= maxRows || !includeRemainder || maxRows == 1
            ? min(shown.count, maxRows)
            : maxRows - 1

        var rows: [CategoryStatsRow] = []
        for (rank, category) in shown.prefix(ownRows).enumerated() {
            rows.append(CategoryStatsRow(
                kind: .category(rank: rank), name: category.name, colorHex: category.colorHex,
                hours: category.hours, share: category.hours / total, percent: 0
            ))
        }
        let rest = shown.dropFirst(ownRows)
        let restHours = rest.reduce(0) { $0 + $1.hours }
        let rounded = percents(rows.map(\.hours) + (rest.isEmpty ? [] : [restHours]))
        for index in rows.indices { rows[index].percent = rounded[index] }
        if !rest.isEmpty, includeRemainder, maxRows > 1 {
            rows.append(CategoryStatsRow(
                kind: .remainder(count: rest.count), name: "", colorHex: nil,
                hours: restHours, share: restHours / total, percent: rounded[rows.count]
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
