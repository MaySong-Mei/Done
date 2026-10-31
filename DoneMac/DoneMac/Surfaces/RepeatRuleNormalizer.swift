//
//  RepeatRuleNormalizer.swift
//  DoneMac
//
//  ONE normalizer for the repeat rule, shared by the create composer and the
//  inspector's rule editor (QA F5 / review F6: two hand-rolled copies had
//  already drifted — one floored the count, one didn't). Rules:
//   - a `.none` cadence forces all end fields off (no end without a cadence),
//   - an `.onDate` end with no date falls back to a month out (review #1:
//     a nil `.onDate` end collapses the series to one occurrence),
//   - counts and intervals floor at 1.
//  The `now`-derived fallback uses `startOfDay(now)` so the two former copies
//  (and the control's default) can't diverge on time-of-day.
//

import Foundation

enum RepeatRuleNormalizer {
    struct Rule {
        var unit: Event.RepeatUnit
        var interval: Int
        var endType: Event.RepeatEndType
        var endDate: Date?
        var endCount: Int?

        func apply(to event: inout Event) {
            event.repeatUnit = unit
            event.repeatInterval = interval
            event.repeatEndType = endType
            event.repeatEndDate = endDate
            event.repeatEndCount = endCount
        }
    }

    static func normalized(unit: Event.RepeatUnit, interval: Int,
                           endType: Event.RepeatEndType, endDate: Date?, endCount: Int?,
                           now: Date, calendar: Calendar) -> Rule {
        let interval = max(1, interval)
        guard unit != .none else {
            return Rule(unit: .none, interval: interval, endType: .none, endDate: nil, endCount: nil)
        }
        switch endType {
        case .none:
            return Rule(unit: unit, interval: interval, endType: .none, endDate: nil, endCount: nil)
        case .onDate:
            let date = endDate ?? calendar.startOfDay(for: now).addingTimeInterval(30 * 86_400)
            return Rule(unit: unit, interval: interval, endType: .onDate, endDate: date, endCount: nil)
        case .afterCount:
            return Rule(unit: unit, interval: interval, endType: .afterCount,
                        endDate: nil, endCount: max(1, endCount ?? 1))
        }
    }
}
