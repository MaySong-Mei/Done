//
//  CalendarEventFormData.swift
//  Done
//
//  The composer's saved values, as plain data. Moved verbatim out of
//  CalendarEventFormView.swift so the type-inference service (and the Mac
//  target, which compiles that service) can use it without the iOS form view.
//

import Foundation

struct CalendarEventFormData {
    let title: String
    let typeTitle: String
    let note: String
    let location: String
    let startTime: Date
    let endTime: Date
    let isAllDay: Bool
    let repeatUnit: Event.RepeatUnit
    let repeatInterval: Int
    let repeatEndType: Event.RepeatEndType
    let repeatEndDate: Date?
    let repeatEndCount: Int?
    let didExplicitlySelectType: Bool
    var agenticIntake: AgenticIntakeRecord? = nil
    /// Behavioral kind selected in the composer. Defaults to `.event` so
    /// existing call sites that construct `CalendarEventFormData` without
    /// specifying a kind keep their current behavior.
    var kind: Event.Kind = .event
    /// Optional hard time constraint. Only the composer surfaces this when
    /// `kind == .todo`, but the value rides through to `Event.deadline`
    /// regardless of kind (so transient kind flips in the form don't
    /// silently drop it).
    var deadline: Date? = nil
    /// People bound to the event ("with whom"). Resolved to `Person` ids;
    /// empty means no one bound. Defaults to `[]` so existing call sites that
    /// build `CalendarEventFormData` keep compiling unchanged.
    var peopleIDs: [UUID] = []

    /// The all-day storage snap the form's save applies: storage carries an
    /// all-day event as concrete instants covering its civil days in the
    /// saving frame. Extracted from the Done-button closure so the composite
    /// path a traveled instance's edit takes — projection seed
    /// (`EditCalendarEventView.occurrenceSeedRange`) → this snap — is
    /// testable against the production reduction itself (gh#188).
    static func allDayStorageStart(for startTime: Date, calendar: Calendar) -> Date {
        calendar.startOfDay(for: startTime)
    }

    /// gh#207 (R1): the end-day anchor is residue-aware. A seed pair
    /// carrying the legacy straddle signature (see
    /// `Event.legacyAllDayStraddleHealedEnd`) has its end one civil day past
    /// the day the user actually picked; anchoring `endOfDay` on it would
    /// stretch storage to two full days — the entrenchment this branch
    /// stops. Judge the RAW seed pair: `seedStart` must be the form's
    /// un-snapped start (snapping it first would put every create-flow seed
    /// on a civil midnight and destroy the signature's genuine-pick
    /// discriminator).
    static func allDayStorageEnd(for endTime: Date, seedStart: Date, calendar: Calendar) -> Date {
        if let healed = Event.legacyAllDayStraddleHealedEnd(
            start: seedStart, end: endTime, calendar: calendar
        ) {
            return healed
        }
        return Event.endOfDay(for: endTime, calendar: calendar)
    }

    func toEvent() -> Event {
        Event(
            title: title,
            note: note,
            location: location,
            timeRanges: [Event.TimeRange(start: startTime, end: endTime)],
            deadline: deadline,
            repeatUnit: repeatUnit,
            isAllDay: isAllDay,
            repeatInterval: repeatInterval,
            repeatEndType: repeatEndType,
            repeatEndDate: repeatEndDate,
            repeatEndCount: repeatEndCount,
            type: typeTitle,
            kind: kind,
            agenticIntake: agenticIntake,
            peopleIDs: peopleIDs.isEmpty ? nil : peopleIDs
        )
    }

    func apply(to event: Event) -> Event {
        var updated = event
        updated.title = title
        updated.type = typeTitle
        updated.kind = kind
        updated.deadline = deadline
        updated.note = note
        updated.location = location
        updated.isAllDay = isAllDay
        // This sheet exposes exactly one range's start/end (the primary —
        // `EditCalendarEventView.occurrenceSeedRange`, `.first` of the
        // projected ranges). Overwriting the whole array destroyed ranges
        // 2..n the sheet never showed or offered for edit (gh#189); write
        // only the range this sheet edits and carry the rest through
        // unchanged, in their own stored frame — the same treatment an
        // untouched primary range already gets from
        // `rebasedExceptionInstanceAfterRangeWrite`. `event`, not `updated`,
        // is deliberate: it's the pre-edit array before this call touched it.
        updated.timeRanges = [Event.TimeRange(start: startTime, end: endTime)] + event.timeRanges.dropFirst()
        updated.repeatUnit = repeatUnit
        updated.repeatInterval = repeatInterval
        updated.repeatEndType = repeatEndType
        updated.repeatEndDate = repeatEndDate
        updated.repeatEndCount = repeatEndCount
        updated.agenticIntake = agenticIntake
        updated.peopleIDs = peopleIDs.isEmpty ? nil : peopleIDs
        return updated
    }
}
