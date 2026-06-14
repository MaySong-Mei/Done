//
//  EventZone.swift
//  Done
//

import Foundation

/// Classifies an item's date relative to NOW + HORIZON — the two-pointer
/// model that defines the calendar's three zones of behavior.
///
/// This is the foundation for the calendar/todo unification design (see
/// `calendar-todo-unification` and `calendar-design-bedrock` in auto-memory).
/// Subsequent slices layer behavior on top of this classification:
///
/// - `.pass`       — strictly past (`date < now`). Future slice will render
///                   sediment + age-fade; user can drag back to revive.
/// - `.nearFuture` — between NOW and HORIZON. Bedrock rule: **system never
///                   modifies date here**. User has full control.
/// - `.future`     — at or beyond HORIZON. Subject to domino push-back when
///                   HORIZON advances (the only zone where the system may
///                   mutate the date, and only under the user's HORIZON
///                   contract). Precision drops to day-level; pulling an
///                   item across HORIZON restores its timeOfDay.
enum EventZone: String, Codable, CaseIterable {
    case pass
    case nearFuture
    case future

    /// Classify a date relative to a NOW moment and a HORIZON moment.
    /// Boundary convention: `date == now` → `.nearFuture`; `date == horizon`
    /// → `.future` (HORIZON is the first moment of "future").
    static func classify(date: Date, now: Date, horizon: Date) -> EventZone {
        if date < now { return .pass }
        if date >= horizon { return .future }
        return .nearFuture
    }

    /// HORIZON moment derived from a day offset.  Returns the PRECISE
    /// time `now + horizonDays × 86400s` — pure-seconds arithmetic, NOT
    /// wall-clock days.  Critical for the Domino-push math: the push
    /// computes `delta = now − last` in pure seconds, and shifts events
    /// by that delta; the filter `firstStart >= horizonAtLast` must use
    /// the SAME unit, or DST transitions (where wall-clock days are 23h
    /// or 25h) make the filter advance 1h faster than the push and
    /// silently abandon events.  Visual line tracks the same value so
    /// it and the data stay in sync; the only artifact is a ~1h drift
    /// of the line position on the 2 DST-transition days per year,
    /// which is preferable to permanent event drift.
    static func horizonDate(
        from horizonDays: Int,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Date {
        return now.addingTimeInterval(Double(horizonDays) * 86400)
    }

    /// Default HORIZON span when the user hasn't set
    /// `AppSettingsKeys.nearFutureHorizonDays`. One week is the natural
    /// "recent" boundary.
    static let defaultHorizonDays: Int = 7
}
