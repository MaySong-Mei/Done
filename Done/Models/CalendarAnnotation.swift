//
//  CalendarAnnotation.swift
//  Done
//
//  Lightweight, display-only date annotations (Chinese 24 solar terms +
//  common Gregorian holidays). These are NOT events: they never appear in
//  the timeline as blocks, never sync, and cannot be tapped or edited. They
//  are computed per-year on demand and rendered as small labels on calendar
//  dates (month cells + the day-view header capsule).
//
//  The model is intentionally open to new `Kind`s (e.g. a future countdown
//  annotation) without touching the rendering call sites.
//

import Foundation

// MARK: - Annotation model

enum CalendarAnnotationKind {
    case solarTerm    // 二十四节气
    case holiday      // 公历节日
    case anniversary  // 用户自定义纪念日
}

/// A user-defined anniversary. Recurs yearly on its `date`'s month/day.
/// `personID` optionally links it to a `Person` (e.g. a wedding anniversary
/// tied to a partner). Persisted as JSON under `AppSettingsKeys.customAnniversaries`.
struct CustomAnniversary: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var date: Date
    var personID: UUID?
}

/// Load/save helper for the persisted custom anniversary list. Decoding is
/// cached on the raw JSON string so repeated reads (one per visible month
/// cell) don't re-parse every render; the cache self-invalidates when the
/// stored string changes.
enum CustomAnniversaryStore {
    static func decode(_ raw: String) -> [CustomAnniversary] {
        guard !raw.isEmpty,
              let data = raw.data(using: .utf8),
              let list = try? JSONDecoder().decode([CustomAnniversary].self, from: data)
        else { return [] }
        return list
    }

    static func encode(_ list: [CustomAnniversary]) -> String {
        guard let data = try? JSONEncoder().encode(list),
              let raw = String(data: data, encoding: .utf8) else { return "" }
        return raw
    }

    private static var cache: (raw: String, list: [CustomAnniversary])?

    static func load() -> [CustomAnniversary] {
        let raw = UserDefaults.standard.string(forKey: AppSettingsKeys.customAnniversaries) ?? ""
        if let cache, cache.raw == raw { return cache.list }
        let list = decode(raw)
        cache = (raw, list)
        return list
    }
}

struct CalendarAnnotation: Identifiable {
    let title: String
    let kind: CalendarAnnotationKind

    var id: String { "\(kind)-\(title)" }
}

// MARK: - Public lookup

enum CalendarAnnotations {
    /// Whether the 24-solar-terms set is shown. Defaults to ON.
    static var solarTermsEnabled: Bool {
        UserDefaults.standard.object(forKey: AppSettingsKeys.holidaysShowSolarTerms) as? Bool ?? true
    }

    /// Whether the Gregorian-holiday set is shown. Defaults to ON.
    static var gregorianHolidaysEnabled: Bool {
        UserDefaults.standard.object(forKey: AppSettingsKeys.holidaysShowGregorianHolidays) as? Bool ?? true
    }

    /// Returns the annotations that fall on `date`'s calendar day, honoring
    /// the user's enabled sets. Solar term first (at most one), then holidays.
    static func annotations(on date: Date, calendar: Calendar = .current) -> [CalendarAnnotation] {
        var result: [CalendarAnnotation] = []
        // User-defined anniversaries first — they're the most personal.
        for anniversary in CustomAnniversaryStore.load()
        where isSameMonthDay(anniversary.date, date, calendar: calendar) {
            result.append(CalendarAnnotation(title: anniversary.title, kind: .anniversary))
        }
        if solarTermsEnabled, let term = SolarTerms.name(on: date, calendar: calendar) {
            result.append(CalendarAnnotation(title: term, kind: .solarTerm))
        }
        if gregorianHolidaysEnabled {
            for name in GregorianHolidays.names(on: date, calendar: calendar) {
                result.append(CalendarAnnotation(title: name, kind: .holiday))
            }
        }
        return result
    }

    /// Whether the day carries any annotation, ignoring the display toggles.
    /// Used by the achievement system so the "festive" easter egg can still
    /// be earned even when the user has hidden the labels.
    static func hasAnyAnnotation(on date: Date, calendar: Calendar = .current) -> Bool {
        if CustomAnniversaryStore.load().contains(where: { isSameMonthDay($0.date, date, calendar: calendar) }) {
            return true
        }
        return SolarTerms.name(on: date, calendar: calendar) != nil
            || !GregorianHolidays.names(on: date, calendar: calendar).isEmpty
    }

    /// Yearly recurrence match: same month + day, any year.
    private static func isSameMonthDay(_ a: Date, _ b: Date, calendar: Calendar) -> Bool {
        let ca = calendar.dateComponents([.month, .day], from: a)
        let cb = calendar.dateComponents([.month, .day], from: b)
        return ca.month == cb.month && ca.day == cb.day
    }
}

// MARK: - 24 Solar Terms (二十四节气)

/// Computes the 24 solar terms astronomically (no per-century constant table,
/// so it stays accurate across years). A term occurs at the instant the Sun's
/// apparent ecliptic longitude reaches a multiple of 15°; the calendar day of
/// that instant — expressed in the supplied `calendar`'s time zone — is when
/// the term is shown.
enum SolarTerms {
    /// Names indexed by `longitude / 15` (0 == 0° == 春分 ... 23 == 345° == 惊蛰).
    private static let names: [(zh: String, en: String)] = [
        ("春分", "Spring Equinox"),       // 0°
        ("清明", "Pure Brightness"),      // 15°
        ("谷雨", "Grain Rain"),           // 30°
        ("立夏", "Start of Summer"),      // 45°
        ("小满", "Grain Buds"),           // 60°
        ("芒种", "Grain in Ear"),         // 75°
        ("夏至", "Summer Solstice"),      // 90°
        ("小暑", "Minor Heat"),           // 105°
        ("大暑", "Major Heat"),           // 120°
        ("立秋", "Start of Autumn"),      // 135°
        ("处暑", "End of Heat"),          // 150°
        ("白露", "White Dew"),            // 165°
        ("秋分", "Autumn Equinox"),       // 180°
        ("寒露", "Cold Dew"),             // 195°
        ("霜降", "Frost's Descent"),      // 210°
        ("立冬", "Start of Winter"),      // 225°
        ("小雪", "Minor Snow"),           // 240°
        ("大雪", "Major Snow"),           // 255°
        ("冬至", "Winter Solstice"),      // 270°
        ("小寒", "Minor Cold"),           // 285°
        ("大寒", "Major Cold"),           // 300°
        ("立春", "Start of Spring"),      // 315°
        ("雨水", "Rain Water"),           // 330°
        ("惊蛰", "Awakening of Insects")  // 345°
    ]

    private static func localizedName(forIndex index: Int) -> String {
        let pair = names[index % 24]
        return AppLanguage.current == .chinese ? pair.zh : pair.en
    }

    /// Beijing-time calendar used to assign each term to its conventional
    /// civil date — solar terms are defined in China Standard Time, so the
    /// term's day must not drift with the device's time zone.
    private static let beijingCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? TimeZone(secondsFromGMT: 8 * 3600)!
        return cal
    }()

    /// Returns the solar term name for the given day, or nil if no term lands
    /// on it. Lookup is by nominal civil date (year/month/day) so it is
    /// independent of the device time zone. Cached per year.
    ///
    /// The 24 solar terms are a Chinese-calendar concept, so they only surface
    /// in Chinese mode; English mode shows US holidays instead and never these.
    static func name(on date: Date, calendar: Calendar) -> String? {
        guard AppLanguage.current == .chinese else { return nil }
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = comps.year, let month = comps.month, let day = comps.day else { return nil }
        guard let index = termsByDate(forYear: year)["\(month)-\(day)"] else { return nil }
        return localizedName(forIndex: index)
    }

    // Cache keyed by Gregorian year → "month-day" → term index (language-
    // independent, so a language switch re-localizes without invalidation).
    private static var cache: [Int: [String: Int]] = [:]

    private static func termsByDate(forYear year: Int) -> [String: Int] {
        if let cached = cache[year] { return cached }

        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? beijingCalendar.timeZone
        // Scan with a margin around the year so terms near the New Year
        // boundary are captured, then keep only those whose Beijing-time
        // civil date falls in `year`.
        guard
            let start = utc.date(from: DateComponents(year: year - 1, month: 12, day: 25)),
            let end = utc.date(from: DateComponents(year: year + 1, month: 1, day: 6))
        else {
            return [:]
        }

        var map: [String: Int] = [:]
        let coarseStep: TimeInterval = 6 * 3600
        var t = start
        var prevLon = sunEclipticLongitude(t)
        while t < end {
            let next = t + coarseStep
            let lon = sunEclipticLongitude(next)
            for theta in crossedMultiplesOf15(from: prevLon, to: lon) {
                let instant = refineCrossing(target: Double(theta), lower: t, upper: next)
                let comps = beijingCalendar.dateComponents([.year, .month, .day], from: instant)
                if comps.year == year, let month = comps.month, let day = comps.day {
                    map["\(month)-\(day)"] = theta / 15
                }
            }
            prevLon = lon
            t = next
        }

        cache[year] = map
        return map
    }

    /// Multiples of 15° crossed when longitude advances from `a` to `b`
    /// (handles the 360°→0° wrap once per year, around the spring equinox).
    private static func crossedMultiplesOf15(from a: Double, to b: Double) -> [Int] {
        var result: [Int] = []
        let advanced = b >= a ? b : b + 360
        // First multiple strictly greater than `a`.
        var theta = (Int(a) / 15 + 1) * 15
        while Double(theta) <= advanced {
            result.append(((theta % 360) + 360) % 360)
            theta += 15
        }
        return result
    }

    /// Binary-search the instant the Sun's longitude reaches `target` (deg).
    private static func refineCrossing(target: Double, lower: Date, upper: Date) -> Date {
        var lo = lower
        var hi = upper
        for _ in 0..<40 {
            let mid = lo.addingTimeInterval(hi.timeIntervalSince(lo) / 2)
            // Distance from `target`, normalized to (-180, 180].
            let delta = normalizedSignedDelta(sunEclipticLongitude(mid) - target)
            if delta < 0 {
                lo = mid
            } else {
                hi = mid
            }
        }
        return lo.addingTimeInterval(hi.timeIntervalSince(lo) / 2)
    }

    private static func normalizedSignedDelta(_ degrees: Double) -> Double {
        var d = degrees.truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d <= -180 { d += 360 }
        return d
    }

    /// Low-precision Sun apparent ecliptic longitude in degrees [0, 360),
    /// accurate to ~0.01° — ample for resolving the calendar day of a term.
    /// (Astronomical Almanac low-precision formula.)
    private static func sunEclipticLongitude(_ date: Date) -> Double {
        let jd = date.timeIntervalSince1970 / 86400.0 + 2440587.5
        let n = jd - 2451545.0
        let meanLon = (280.460 + 0.9856474 * n).truncatingRemainder(dividingBy: 360)
        let meanAnomDeg = (357.528 + 0.9856003 * n).truncatingRemainder(dividingBy: 360)
        let g = meanAnomDeg * .pi / 180
        var lambda = meanLon + 1.915 * sin(g) + 0.020 * sin(2 * g)
        lambda = lambda.truncatingRemainder(dividingBy: 360)
        if lambda < 0 { lambda += 360 }
        return lambda
    }
}

// MARK: - Gregorian holidays (公历节日)

/// Gregorian-calendar holidays, picked by the app language: Chinese mode shows
/// the holidays observed in China, English mode shows the common US holidays.
/// Lunar festivals (春节, 端午, 中秋 …) are intentionally excluded for now —
/// they need lunar→solar conversion and can be added as a separate set later.
enum GregorianHolidays {
    /// Holidays observed in China (all fixed Gregorian dates).
    private static let chineseEntries: [(month: Int, day: Int, name: String)] = [
        (1, 1, "元旦"),
        (2, 14, "情人节"),
        (3, 8, "妇女节"),
        (4, 1, "愚人节"),
        (5, 1, "劳动节"),
        (5, 4, "青年节"),
        (6, 1, "儿童节"),
        (7, 1, "建党节"),
        (8, 1, "建军节"),
        (9, 10, "教师节"),
        (10, 1, "国庆节"),
        (12, 24, "平安夜"),
        (12, 25, "圣诞节")
    ]

    /// US holidays that fall on a fixed Gregorian date.
    private static let usFixedEntries: [(month: Int, day: Int, name: String)] = [
        (1, 1, "New Year's Day"),
        (2, 14, "Valentine's Day"),
        (3, 17, "St. Patrick's Day"),
        (7, 4, "Independence Day"),
        (10, 31, "Halloween"),
        (11, 11, "Veterans Day"),
        (12, 24, "Christmas Eve"),
        (12, 25, "Christmas"),
        (12, 31, "New Year's Eve")
    ]

    /// US holidays defined as the Nth weekday of a month. `weekday` is the
    /// Gregorian weekday (1 = Sunday … 7 = Saturday); `ordinal` is the
    /// occurrence within the month, or -1 for "the last one".
    private static let usFloatingEntries: [(month: Int, weekday: Int, ordinal: Int, name: String)] = [
        (1, 2, 3, "MLK Day"),          // 3rd Monday of January
        (2, 2, 3, "Presidents' Day"),  // 3rd Monday of February
        (5, 1, 2, "Mother's Day"),     // 2nd Sunday of May
        (5, 2, -1, "Memorial Day"),    // last Monday of May
        (6, 1, 3, "Father's Day"),     // 3rd Sunday of June
        (9, 2, 1, "Labor Day"),        // 1st Monday of September
        (10, 2, 2, "Columbus Day"),    // 2nd Monday of October
        (11, 5, 4, "Thanksgiving")     // 4th Thursday of November
    ]

    static func names(on date: Date, calendar: Calendar) -> [String] {
        let comps = calendar.dateComponents([.year, .month, .day, .weekday], from: date)
        guard let month = comps.month, let day = comps.day else { return [] }

        if AppLanguage.current == .chinese {
            return chineseEntries
                .filter { $0.month == month && $0.day == day }
                .map { $0.name }
        }

        var result = usFixedEntries
            .filter { $0.month == month && $0.day == day }
            .map { $0.name }
        guard let year = comps.year, let weekday = comps.weekday else { return result }
        for entry in usFloatingEntries
        where entry.month == month && entry.weekday == weekday
            && matchesOrdinal(entry.ordinal, day: day, month: month, year: year, calendar: calendar) {
            result.append(entry.name)
        }
        return result
    }

    /// Whether `day` is the `ordinal`-th occurrence of its weekday in the
    /// month. Positive ordinals count from the start; -1 means the last one.
    private static func matchesOrdinal(_ ordinal: Int, day: Int, month: Int, year: Int, calendar: Calendar) -> Bool {
        if ordinal > 0 {
            return (day - 1) / 7 + 1 == ordinal
        }
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              let range = calendar.range(of: .day, in: .month, for: date) else { return false }
        return day + 7 > range.count
    }
}
