//
//  WristCommandApplier.swift
//  Done
//
//  Turns a `WristCommand` into the same store mutations focus mode's quick
//  actions perform (`DoneApp.startTracking` / `applyEndTime` /
//  `applyEndTimeDelta`): start creates one single-range event of the type,
//  named with the title picked on the watch or else after the type;
//  finish and extend rewrite one range's end, grid-snapped and clamped to a
//  15-minute minimum, and are refused for recurring events and running
//  timers. Unlike focus mode, the range edited is the one the command names
//  (`rangeStart`), so a multi-range event's other ranges are left alone.
//
//  A range edit (a block moved or resized on the watch's today page)
//  replaces the one range it names, by the phone's drag rules: refused for
//  recurring events, running timers and all-day events, and for a
//  multi-range event unless the range is named; an edge that moved lands
//  on the grid, a quarter-hour step from where it was, or another block's
//  edge (`WristRangeEdit`), never under the minimum length. The ranges are
//  kept in start order, as the phone's drop keeps them.
//
//  A settings edit writes the fields it carries into Settings → Apple Watch
//  (`AppSettingsKeys.watchStatsSettings`), the storage the phone's own page
//  edits; the bridge pushes the changed snapshot. An edit issued before the
//  last one applied is refused: when two edits cross on different channels
//  the later choice stands.
//

import Foundation

enum WristCommandApplier {
    static let minimumDuration: TimeInterval = 15 * 60
    /// When (watch clock) the last settings edit applied was issued.
    static let settingsEditedAtKey = "wrist.settingsEditedAt"

    @discardableResult
    static func apply(_ command: WristCommand, to store: EventStore, defaults: UserDefaults = .standard) -> WristReceipt {
        switch command.kind {
        case .start(let eventID, let typeTitle, let start, let end, let title):
            if store.findCalendarEvent(id: eventID) != nil {
                return WristReceipt(id: command.id, outcome: .duplicate, reason: nil)
            }
            let type = typeTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !type.isEmpty else { return rejected(command, "empty type") }
            guard end > start else { return rejected(command, "invalid range") }
            store.addCalendarEvent(
                Event(
                    id: eventID,
                    title: WristCommand.storedTitle(typeTitle: type, title: title),
                    timeRanges: [Event.TimeRange(start: start, end: end)],
                    type: type
                ),
                creationMotion: .remote
            )
            return WristReceipt(id: command.id, outcome: .applied, reason: nil)

        case .finish(let eventID, let rangeStart, let at):
            return setEnd(of: eventID, rangeStart: rangeStart, command: command, store: store) { _ in at }

        case .extend(let eventID, let rangeStart, let by):
            return setEnd(of: eventID, rangeStart: rangeStart, command: command, store: store) { range in
                range.end.addingTimeInterval(by)
            }

        case .setRange(let eventID, let rangeStart, let start, let end):
            return setRange(of: eventID, rangeStart: rangeStart, start: start, end: end, command: command, store: store)

        case .statsSettings(let overlap, let excludesBackground):
            let issued = command.issuedAt.timeIntervalSince1970
            if let last = defaults.object(forKey: settingsEditedAtKey) as? Double, issued < last {
                return rejected(command, "superseded")
            }
            var settings = WristStatsSettings.load(from: defaults)
            if let overlap { settings.overlap = overlap }
            if let excludesBackground { settings.excludesBackground = excludesBackground }
            defaults.set(issued, forKey: settingsEditedAtKey)
            if settings != WristStatsSettings.load(from: defaults) {
                defaults.set(settings.encoded, forKey: AppSettingsKeys.watchStatsSettings)
            }
            return WristReceipt(id: command.id, outcome: .applied, reason: nil)
        }
    }

    /// The end focus mode would store: snapped to the 15-minute grid, never
    /// earlier than `start + minimumDuration`.
    static func adjustedEnd(start: Date, requested: Date) -> Date {
        max(calendarSnapDateToMinuteGrid(requested), start.addingTimeInterval(minimumDuration))
    }

    /// Which range a command edits: the one starting at `rangeStart` (within
    /// the wire's date tolerance), else the only range. A multi-range event
    /// without a named range is refused rather than guessed.
    static func rangeIndex(in event: Event, rangeStart: Date?) -> Int? {
        if let rangeStart, let named = event.timeRanges.firstIndex(where: {
            WristTiming.sameInstant($0.start, rangeStart)
        }) {
            return named
        }
        return event.timeRanges.count == 1 ? 0 : nil
    }

    private static func setEnd(
        of eventID: UUID, rangeStart: Date?, command: WristCommand, store: EventStore,
        requested: (Event.TimeRange) -> Date
    ) -> WristReceipt {
        guard let event = store.findCalendarEvent(id: eventID) else {
            return rejected(command, "not found")
        }
        guard focusQuickActionAllowedForEvent(event) else {
            return rejected(command, "recurring")
        }
        guard event.timerStartedAt == nil else {
            return rejected(command, "timer")
        }
        guard let index = rangeIndex(in: event, rangeStart: rangeStart) else {
            return rejected(command, event.timeRanges.isEmpty ? "no range" : "range not found")
        }
        let range = event.timeRanges[index]
        var updated = event
        updated.timeRanges[index].end = adjustedEnd(start: range.start, requested: requested(range))
        if updated.timeRanges[index].end != range.end {
            store.updateCalendarEvent(updated)
        }
        return WristReceipt(id: command.id, outcome: .applied, reason: nil)
    }

    private static func setRange(
        of eventID: UUID, rangeStart: Date?, start: Date, end: Date, command: WristCommand, store: EventStore
    ) -> WristReceipt {
        guard let event = store.findCalendarEvent(id: eventID) else {
            return rejected(command, "not found")
        }
        guard focusQuickActionAllowedForEvent(event) else {
            return rejected(command, "recurring")
        }
        guard event.timerStartedAt == nil else {
            return rejected(command, "timer")
        }
        guard !event.isAllDay else {
            return rejected(command, "all day")
        }
        guard let index = rangeIndex(in: event, rangeStart: rangeStart) else {
            return rejected(command, event.timeRanges.isEmpty ? "no range" : "range not found")
        }
        let range = event.timeRanges[index]
        guard let settled = WristRangeEdit.settled(
            original: WristTimeSpan(start: range.start, end: range.end),
            requested: WristTimeSpan(start: start, end: end),
            edges: neighborEdges(of: eventID, rangeStart: range.start, around: [start, end], in: store)
        ) else {
            return rejected(command, "invalid range")
        }
        guard settled.start != range.start || settled.end != range.end else {
            return WristReceipt(id: command.id, outcome: .applied, reason: nil)
        }
        var updated = event
        updated.timeRanges[index] = Event.TimeRange(start: settled.start, end: settled.end)
        updated.timeRanges.sort { $0.start < $1.start }
        store.updateCalendarEvent(updated)
        return WristReceipt(id: command.id, outcome: .applied, reason: nil)
    }

    /// The edges of every other block on the days the edit touches (the
    /// event's other ranges included) — what the watch's magnet could have
    /// held an edge on.
    private static func neighborEdges(
        of eventID: UUID, rangeStart: Date, around dates: [Date], in store: EventStore
    ) -> [Date] {
        let calendar = Calendar.current
        let days = Set(dates.map { calendar.startOfDay(for: $0) })
        let events = store.canvasRenderableCalendarEvents
        return days.flatMap { day in
            CalendarLayout.occurrencesForDate(events, date: day, calendar: calendar)
                .filter { !($0.event.id == eventID && WristTiming.sameInstant($0.range.start, rangeStart)) }
                .flatMap { [$0.range.start, $0.range.end] }
        }
    }

    private static func rejected(_ command: WristCommand, _ reason: String) -> WristReceipt {
        WristReceipt(id: command.id, outcome: .rejected, reason: reason)
    }
}
