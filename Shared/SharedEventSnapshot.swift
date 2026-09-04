import Foundation

/// Lightweight event snapshot shared between the main app and widget via App Group UserDefaults.
///
/// One value = one **occurrence**, not one event: a recurring series expands to
/// one snapshot per rendered day, and a multi-range (cross-midnight) event to
/// one snapshot per range.  `id` is therefore per-occurrence — see
/// `occurrenceID(eventID:occurrenceStart:)` — while `eventID` carries the
/// underlying `Event.id` so the widget can still group occurrences back onto
/// their event (interrupt → parent lookup today, deep links later).
///
/// Codable compatibility matters in BOTH directions: the App Group blob outlives
/// an app upgrade (a freshly-installed widget can read a blob the previous app
/// version wrote, and vice versa), so every field added here must be optional
/// (missing key decodes to nil) and every reader must degrade instead of
/// failing.  `resolvedEventID` is that degradation for `eventID`.
struct SharedEventSnapshot: Codable, Hashable {
    /// Identity of THIS occurrence. Unique within one snapshot payload.
    var id: UUID
    /// `Event.id` of the event this occurrence came from. Optional only for
    /// backwards decode of blobs written before per-occurrence ids existed —
    /// read it through `resolvedEventID`.
    var eventID: UUID?
    var title: String
    var type: String
    var colorHex: String?
    var startDate: Date
    var endDate: Date
    var isAllDay: Bool
    var isDone: Bool
    var isInterrupt: Bool?
    var parentEventID: UUID?

    /// The underlying event id, with a fallback for legacy blobs where `id`
    /// *was* the event id.
    var resolvedEventID: UUID { eventID ?? id }

    /// Deterministic per-occurrence identity: `(event, occurrence start,
    /// ordinal)` always maps to the same UUID.  Deterministic (not `UUID()`) so
    /// a snapshot rewrite that changes nothing keeps the same ids — SwiftUI's
    /// `ForEach` identity in the widget then animates in place instead of
    /// tearing the row down.
    ///
    /// The end date is deliberately NOT mixed in: stretching an occurrence
    /// should keep its identity.  That leaves `(event, start)` non-unique for
    /// one reachable shape — two ranges of the SAME event starting at the same
    /// instant.  `calendarUpdatedRangesAfterDrop` is the live producer: it
    /// replaces the dragged range of a multi-range (cross-midnight) event in
    /// place, never checking whether the dropped start already belongs to a
    /// sibling range, and `CalendarPageView` writes the result straight into
    /// `rawCalendarEvents` — the array this projection reads.  The canvas draws
    /// both blocks (`CalendarLayout.occurrencesForDate` mixes the end into its
    /// id), so the widget must carry both too — `ordinal` is the tiebreaker
    /// that keeps them distinct without making a resize churn identity.
    ///
    /// `ordinal == 0` (the only value any non-degenerate payload uses) is
    /// exactly the `(resolvedEventID, startDate)` composite, so an ordinary
    /// snapshot's id stays recomputable from the snapshot itself. Only the
    /// duplicate-start siblings need their position to be reproduced, and the
    /// builder is the single place that assigns it.
    static func occurrenceID(eventID: UUID, occurrenceStart: Date, ordinal: Int = 0) -> UUID {
        // Millisecond resolution — below the granularity any UI can produce,
        // above the float noise of `timeIntervalSince1970`.
        let millis = (occurrenceStart.timeIntervalSince1970 * 1000).rounded()
        // Clamp rather than trap. `Date.distantFuture` is ~6.4e13 ms, five
        // orders of magnitude short of `Int64.max` — the real hazards are a
        // NaN/infinite interval out of a corrupt decode and the absurd dates a
        // hand-edited blob can carry, both of which would trap the `Int64` init.
        let clamped = millis.isFinite ? min(max(millis, -9.0e18), 9.0e18) : 0
        var z = UInt64(bitPattern: Int64(clamped)) &+ 0x9E37_79B9_7F4A_7C15
        // Odd multiplier so a nonzero ordinal always perturbs the seed, and
        // `ordinal == 0` leaves it byte-identical to the two-argument form.
        z = z &+ (UInt64(bitPattern: Int64(ordinal)) &* 0xD6E8_FEB8_6659_FD93)
        // splitmix64 finalizer — avalanches adjacent timestamps into unrelated
        // bit patterns so consecutive days can't alias.
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= (z >> 31)

        var bytes = eventID.uuid
        withUnsafeMutableBytes(of: &bytes) { raw in
            withUnsafeBytes(of: z.bigEndian) { mix in
                // Keep the event's high 8 bytes intact so the id stays visibly
                // derived from its event when eyeballing a dumped blob.
                for i in 0..<8 { raw[8 + i] ^= mix[i] }
            }
        }
        return UUID(uuid: bytes)
    }
}

enum SharedWidgetData {
    static let appGroupID = "group.wordless.shiqiliuyifanmei.app"
    static let snapshotKey = "widgetEventSnapshots"
    static let lastUpdatedKey = "widgetLastUpdated"

    /// Whether THIS process is actually entitled to the App Group.
    ///
    /// `UserDefaults(suiteName:)` is not a membership check.  It returns nil
    /// only for the process' own bundle id and the global domain; for any other
    /// string — including a group id the target has no
    /// `com.apple.security.application-groups` entitlement for — it hands back a
    /// perfectly usable suite that quietly lands in the process' OWN
    /// `Library/Preferences`.  That is exactly how gh#142 stayed invisible: the
    /// app wrote, every call reported success, and the widget (which reads the
    /// real shared container) saw an empty payload forever.
    ///
    /// `containerURL(forSecurityApplicationGroupIdentifier:)` returns nil
    /// without the entitlement, so it is the honest probe.  Cached because it
    /// hits the filesystem and membership cannot change while the process runs.
    static let isMemberOfAppGroup: Bool =
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) != nil

    static var sharedDefaults: UserDefaults? {
        guard isMemberOfAppGroup else { return nil }
        return UserDefaults(suiteName: appGroupID)
    }

    static let timeFormatKey = "widgetTimeFormat"
    static let languageKey = "widgetLanguage"
    /// IANA identifier of the time zone the payload was computed in (gh#219
    /// QA F1). Stored beside the payload for the same reason the settings
    /// keys are: the app's launch seed reads the group back to learn "what
    /// does the widget currently show", and a zone the payload was computed
    /// in that differs from the zone the device is in NOW must read as a
    /// payload difference — snapshot dates are absolute instants, so a TZ
    /// move can leave the bytes identical while every rendered hour label
    /// is wrong.
    static let timeZoneKey = "widgetTimeZone"

    /// Returns false when the payload never reached the App Group: this target
    /// is not entitled to the group (see `isMemberOfAppGroup` — the silent
    /// failure this guards), the suite could not be opened, or the payload did
    /// not encode.  Callers that cache "what was last written" must only update
    /// that cache on `true` — otherwise a one-off failure is remembered as a
    /// success and the identical payload is never retried.
    ///
    /// It does NOT promise the bytes are durable on disk: `UserDefaults` flushes
    /// the container plist asynchronously (observed lag of tens of seconds), so
    /// a `true` means "handed to the right suite", not "readable by the widget
    /// this instant".
    ///
    /// `timeZone` has no default on purpose: the caller must pass the zone
    /// the snapshots were actually computed in, and a silent
    /// `TimeZone.current` default at THIS layer could stamp a payload that
    /// some future caller computed in a different calendar.
    @discardableResult
    static func write(events: [SharedEventSnapshot], timeFormat: String = "24h", language: String = "en", timeZone: String) -> Bool {
        guard let defaults = sharedDefaults else { return false }
        guard let data = try? JSONEncoder().encode(events) else { return false }
        defaults.set(data, forKey: snapshotKey)
        defaults.set(Date(), forKey: lastUpdatedKey)
        defaults.set(timeFormat, forKey: timeFormatKey)
        defaults.set(language, forKey: languageKey)
        defaults.set(timeZone, forKey: timeZoneKey)
        return true
    }

    static func read() -> [SharedEventSnapshot] {
        guard let defaults = sharedDefaults,
              let data = defaults.data(forKey: snapshotKey),
              let events = try? JSONDecoder().decode([SharedEventSnapshot].self, from: data) else {
            return []
        }
        return events
    }
}

/// Display schedule for the widget's timeline (gh#219).
///
/// The provider used to ship ONE entry with a `.after(now + 5 minutes)`
/// policy — 288 requested refreshes/day against WidgetKit's ~40-70/day
/// budget. Refresh-budget exhaustion throttles EVERY reload for the process,
/// including the app's own hash-guarded `reloadAllTimelines` push — so the
/// "always fresh" pull policy is exactly what made the widget go stale.
///
/// The replacement inverts the roles: hand WidgetKit a full day of entries up
/// front — re-rendering an already-delivered entry costs no budget at all —
/// and request a new timeline only when the schedule runs out (`.atEnd`, whose
/// last entry is the next day boundary: about one requested refresh per day).
/// Data changes keep arriving instantly through the app's push; this schedule
/// only has to keep the DISPLAY honest between pushes.
///
/// Pure and shared deliberately: the widget target has no test bundle, so
/// this lives in the file both targets compile and gets its behavioural tests
/// from `DoneTests`; the provider's use of it is source-pinned there.
enum WidgetTimelineSchedule {
    /// Hard cap on entries per timeline. WidgetKit truncates oversized
    /// timelines at an undocumented limit (guidance is only "keep timelines
    /// small"), so the schedule enforces its own cap and decides what
    /// survives — `now` and the rollover entry always, then event boundaries,
    /// then ticks strided evenly across the remaining day — instead of
    /// letting WidgetKit cut the tail off blind. A full civil day of 15-minute ticks is 96 entries; 120 leaves
    /// room for a heavy day's event boundaries on top.
    static let maxEntryCount = 120

    /// Gap between periodic re-render ticks. Ticks exist for the
    /// time-anchored chrome — the mini-timeline's now line, the ring's
    /// remaining-minutes label — which would otherwise freeze between event
    /// boundaries. 15 minutes is a display-granularity choice, not a refresh
    /// cost: every tick is a pre-delivered entry, never a budget spend.
    static let tickInterval: TimeInterval = 15 * 60

    /// The next civil day boundary strictly after `now` — the rollover
    /// moment where "today's list" changes meaning. Fallback only guards a
    /// degenerate calendar; DST days (23h/25h) come out of `Calendar`
    /// correctly.
    static func nextDayBoundary(after now: Date, calendar: Calendar) -> Date {
        let dayStart = calendar.startOfDay(for: now)
        if let next = calendar.date(byAdding: .day, value: 1, to: dayStart), next > now {
            return next
        }
        return now.addingTimeInterval(24 * 3600)
    }

    /// Entry dates for one timeline: `now`, every event start/end strictly
    /// inside `(now, rollover)` — the exact moments `currentEvent` /
    /// `nextUpEvent` flip — periodic ticks, and the rollover itself as the
    /// final entry (it carries the NEXT day's list, so a throttled refresh at
    /// midnight degrades to a stale-by-hours now-line, never to yesterday's
    /// events).
    ///
    /// Sorted strictly ascending, first == `now`, last == rollover, count <=
    /// `maxEntryCount`. When the cap bites, ticks are the first to go — and
    /// the ticks that DO fit are strided evenly across `(now, rollover)`
    /// rather than filled chronologically from `now` (gh#219 QA F2: the
    /// chronological fill spent every slot on the near hours, so from ~12
    /// events up the evening chrome froze for >1h stretches while the widget
    /// kept rendering each entry's wall-clock time). Only a day with more
    /// than ~118 event boundaries loses boundaries, by stride-sampling that
    /// always keeps first and last.
    static func entryDates(
        events: [SharedEventSnapshot], now: Date, calendar: Calendar
    ) -> [Date] {
        let rollover = nextDayBoundary(after: now, calendar: calendar)
        var dates: Set<Date> = [now, rollover]
        for event in events where !event.isAllDay {
            for boundary in [event.startDate, event.endDate]
            where boundary > now && boundary < rollover {
                dates.insert(boundary)
            }
        }

        if dates.count > maxEntryCount {
            let sorted = dates.sorted()
            let step = Double(sorted.count - 1) / Double(maxEntryCount - 1)
            var sampled: [Date] = []
            for i in 0..<maxEntryCount {
                let date = sorted[Int((Double(i) * step).rounded())]
                if sampled.last != date { sampled.append(date) }
            }
            return sampled
        }

        // Fill the leftover slots with display ticks — two regimes. When the
        // whole `tickInterval` grid fits the leftover budget, use it
        // unchanged: ticks land on the :00/:15/:30/:45 grid and every gap is
        // at most one tick. When boundaries have eaten into the budget,
        // STRIDE the leftover ticks evenly across (now, rollover) instead of
        // filling chronologically from `now` (gh#219 QA F2): the
        // chronological fill spent every slot on the near hours and let the
        // evening chrome freeze for hours, while an even stride bounds the
        // worst gap all day at span/(budget+1) — a tick landing exactly on a
        // boundary date merely dedups, widening that one gap to at most two
        // strides.
        let budget = maxEntryCount - dates.count
        if budget > 0 {
            let dayStart = calendar.startOfDay(for: now)
            let elapsed = now.timeIntervalSince(dayStart)
            var grid: [Date] = []
            var tick = dayStart.addingTimeInterval(
                (elapsed / tickInterval).rounded(.up) * tickInterval
            )
            while tick < rollover {
                if tick > now { grid.append(tick) }
                tick = tick.addingTimeInterval(tickInterval)
            }
            if grid.count <= budget {
                dates.formUnion(grid)
            } else {
                let spacing = rollover.timeIntervalSince(now) / Double(budget + 1)
                for i in 1...budget {
                    dates.insert(now.addingTimeInterval(spacing * Double(i)))
                }
            }
        }
        return dates.sorted()
    }

    /// The events one entry shows: occurrences overlapping the civil day
    /// containing `date`. Same half-open overlap and all-day exclusion the
    /// provider's old `todayEvents()` applied, single-sourced here so the
    /// rollover entry can carry the next day's list without a second copy of
    /// the rule.
    static func events(
        visibleOn date: Date, from all: [SharedEventSnapshot], calendar: Calendar
    ) -> [SharedEventSnapshot] {
        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        return all
            .filter { $0.endDate > dayStart && $0.startDate < dayEnd && !$0.isAllDay }
            .sorted { $0.startDate < $1.startDate }
    }
}
