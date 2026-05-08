import Foundation

/// Single global "view this calendar in tz X" override (Apple/Google Calendar
/// "Time Zone Override" parity). Persisted as a `String?` identifier in
/// UserDefaults; `nil` means "follow the device's current time zone."
///
/// Resolution is computed on-demand from UserDefaults rather than cached, so
/// SwiftUI views that bind to the same key via `@AppStorage` and call
/// `resolved` after a state mutation see consistent values without explicit
/// invalidation. The resolution path is one dictionary read; callers that
/// need a Calendar in tight loops should fetch `resolvedCalendar` once and
/// reuse it within the loop.
enum CalendarDisplayTimeZone {
    /// UserDefaults key; also used by `@AppStorage` in views.
    static let userDefaultsKey = "calendarOverrideTimeZoneIdentifier"

    /// `TimeZone` to interpret day boundaries and hour positions in across the
    /// calendar grid. Falls back to `TimeZone.current` when no override is
    /// stored, or when the stored identifier no longer resolves on this OS.
    static var resolved: TimeZone {
        if let identifier = UserDefaults.standard.string(forKey: userDefaultsKey),
           let tz = TimeZone(identifier: identifier) {
            return tz
        }
        return TimeZone.current
    }

    /// Gregorian `Calendar` configured with `resolved`. Use this in rendering
    /// code instead of `Calendar.current` so day boundaries shift with the
    /// override.
    static var resolvedCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = resolved
        return calendar
    }

    /// True when the user has explicitly picked a tz different from the
    /// device's current tz. UI uses this to decide whether to show the
    /// "(overriding system)" badge.
    static var isOverrideActive: Bool {
        guard let identifier = UserDefaults.standard.string(forKey: userDefaultsKey),
              let tz = TimeZone(identifier: identifier) else {
            return false
        }
        return tz.identifier != TimeZone.current.identifier
    }
}
