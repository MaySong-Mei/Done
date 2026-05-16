//
//  CalendarMidnightHandler.swift
//  Done
//
//  Pure helpers used by CalendarPageView and ContentView to handle wall-clock
//  midnight crossings while the app is foregrounded.
//
//  The calendar's occurrence cache is keyed by an integer day offset relative
//  to `startOfDay(Date())` at the moment of the last rebuild.  Without an
//  active midnight handler, the cache key meaning drifts as soon as the clock
//  crosses midnight: render-time filters use the live `Date()`, the cached
//  entries do not, and the intersection leaves only events that straddle
//  midnight — see issue #10 for the structural follow-up.
//
//  These helpers exist as pure functions so they can be unit-tested without a
//  SwiftUI view host.
//

import Foundation

enum CalendarMidnightHandler {
    /// Returns the number of calendar days that have elapsed between
    /// `lastKnownStartOfDay` and the start-of-day of `now` in `calendar`.
    /// Zero when nothing changed; negative when the wall clock moved backwards
    /// (e.g., manual system-time change or a DST repeat — both of which we
    /// must tolerate without crashing).
    static func daysCrossed(
        from lastKnownStartOfDay: Date,
        to now: Date,
        calendar: Calendar = .current
    ) -> Int {
        let nowStartOfDay = calendar.startOfDay(for: now)
        return calendar.dateComponents([.day], from: lastKnownStartOfDay, to: nowStartOfDay).day ?? 0
    }
}
