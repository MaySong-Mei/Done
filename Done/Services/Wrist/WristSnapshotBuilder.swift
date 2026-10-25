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
        colorHex: (String) -> String
    ) -> WristSnapshot {
        WristSnapshot(
            generatedAt: now,
            language: language,
            types: rankedTypes(events: events, templates: templates, now: now, calendar: calendar),
            occurrences: occurrences(events: events, now: now, calendar: calendar, colorHex: colorHex),
            receipts: receipts
        )
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
                        isOpenEnded: isTimer
                    )
                )
            }
        }
        return result.sorted { $0.start < $1.start }
    }
}
