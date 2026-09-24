//
//  EventInspectorModel.swift
//  DoneMac
//
//  The interaction hub, Mac-side: a right-inspector edit surface for the
//  selected event — the phone's tap→detail model, made a live pane you
//  edit while the calendar stays visible.
//
//  Mutators are ID-ADDRESSED and take an explicit `now`: a context-menu
//  quick action or a text field flushing on teardown must act on the block
//  it was invoked for, never on whatever happens to be selected at commit
//  time (QA F1/#1 selection corruption, review #3 draft loss).
//
//  RECURRING SERIES (A1b): a field edit on a series occurrence CUSTOMIZES
//  that one occurrence — it materializes a `.single` exception (matching iOS
//  `editOccurrence`) and re-selects the concrete instance. The repeat RULE
//  and DELETE are the only scoped (this/following/all) operations. Nothing
//  is refused; the earlier fail-closed gate is gone.
//
//  Pickers/toggles/dates commit immediately (one store commit each); text
//  fields commit on submit/blur so typing stays a zero-commit action (the
//  budget-5 discipline). Every write goes through the QA'd store path
//  (replaceCalendarEvent seeds from renderTimeRanges and rebases exception
//  mirrors; the effort scrubber is the one sanctioned colorDepth write —
//  the "feedback seam" the plan reserves for concept 4).
//

import SwiftUI

@MainActor
@Observable
final class EventInspectorModel {
    private(set) var selectedID: UUID?

    @ObservationIgnored private let store: MacEventStore
    @ObservationIgnored private let calendar: Calendar

    init(store: MacEventStore, calendar: Calendar) {
        self.store = store
        self.calendar = calendar
    }

    /// The live event, re-read from the store each access so the pane never
    /// edits a stale snapshot.
    var event: Event? {
        guard let selectedID else { return nil }
        return store.calendarEvents.first { $0.id == selectedID }
    }

    /// Presentation follows the SELECTION, not liveness: an event dropped
    /// out-of-band (a sync round-trip) leaves the pane on an honest
    /// "unavailable" state instead of silently closing and then reopening if
    /// the same id ever returns (review #7).
    var isOpen: Bool { selectedID != nil }

    /// The occurrence day the selection was made on — a series renders one
    /// block per occurrence all sharing the template's id, so a field edit
    /// needs to know WHICH day to customize. nil once the selection is a
    /// concrete (non-recurring) row.
    private(set) var selectedOccurrenceDate: Date?

    func select(_ id: UUID, occurrenceDate: Date? = nil) {
        selectedID = id
        selectedOccurrenceDate = occurrenceDate
    }
    func close() { selectedID = nil; selectedOccurrenceDate = nil }

    /// True when the selected row is a recurring series template — the pane
    /// shows the repeat rule + scope controls, and field edits customize a
    /// single occurrence (materializing an exception).
    var isRecurringSeries: Bool { event?.isRecurringSeries ?? false }

    /// Human summary of the current repeat rule (for the Repeat section).
    var repeatSummary: String {
        guard let event, event.repeatUnit != .none else { return "Does not repeat" }
        let n = max(1, event.repeatInterval)
        let unit: String
        switch event.repeatUnit {
        case .none: unit = ""
        case .day: unit = n == 1 ? "day" : "days"
        case .week: unit = n == 1 ? "week" : "weeks"
        case .month: unit = n == 1 ? "month" : "months"
        case .year: unit = n == 1 ? "year" : "years"
        }
        let base = n == 1 ? "Every \(unit)" : "Every \(n) \(unit)"
        switch event.repeatEndType {
        case .none: return base
        case .onDate: return base + " · until a date"
        case .afterCount: return base + " · \(event.repeatEndCount ?? 0)×"
        }
    }

    /// The time range to SHOW and edit — for a series occurrence this is the
    /// selected day's projected range (day + the template's time-of-day +
    /// duration), NOT the template's own day-0 range, so the Time picker
    /// displays and writes the occurrence you clicked (QA F1: seeding from
    /// the template dropped the edit onto day 0 and deleted the real day).
    var occurrenceRange: Event.TimeRange? {
        guard let event else { return nil }
        if event.isRecurringSeries, let day = selectedOccurrenceDate,
           let template = event.primaryTimeRange {
            let start = Event.dateByCombining(day: calendar.startOfDay(for: day),
                                              timeFrom: template.start, calendar: calendar)
            return Event.TimeRange(start: start, end: start.addingTimeInterval(event.duration))
        }
        return event.renderTimeRanges(calendar: calendar).first
    }

    /// Current effort rating derived back from colorDepth, CLAMPED to 1...5:
    /// an off-grid depth from a synced/legacy row (e.g. 0.05 or 1.5) must not
    /// read back as 0 or 8 (QA F2).
    var effortRating: Int? {
        guard let depth = event?.colorDepth, depth > 0 else { return nil }
        return min(max(Int((depth * 5).rounded()), 1), 5)
    }

    // MARK: - Field commits (ID-addressed, now-explicit)

    func setTitle(id: UUID, _ title: String, now: Date) {
        apply(id: id, now: now) { $0.title = title }
    }

    func setNote(id: UUID, _ note: String, now: Date) {
        apply(id: id, now: now) { $0.note = note }
    }

    func setKind(id: UUID, _ kind: Event.Kind, now: Date) {
        apply(id: id, now: now) { $0.kind = kind }
    }

    func setType(id: UUID, _ type: String, now: Date) {
        apply(id: id, now: now) { $0.type = type }
    }

    func setDeadline(id: UUID, _ deadline: Date?, now: Date) {
        apply(id: id, now: now) { $0.deadline = deadline }
    }

    /// The effort scrubber's commit — the sanctioned colorDepth write.
    /// nil clears effort back to the unlogged default.
    func setEffort(id: UUID, _ rating: Int?, now: Date) {
        apply(id: id, now: now) {
            $0.colorDepth = Event.colorDepth(forEffort: rating)
        }
    }

    // MARK: - Todo lifecycle

    func toggleDone(id: UUID, now: Date) {
        apply(id: id, now: now) { event in
            guard event.kind == .todo else { return }
            if event.isDone {
                event.isDone = false
                event.status = .active
                event.completeAt = nil
            } else {
                event.isDone = true
                event.status = .completed
                event.completeAt = now
            }
        }
    }

    /// Context-menu toggle: acts on the right-clicked occurrence (explicit
    /// day), never on the pane's selection, and does not re-select — a
    /// quick action on a possibly-unselected block (#1).
    func toggleDoneOccurrence(id: UUID, occurrenceDate: Date?, now: Date) {
        guard let event = store.calendarEvents.first(where: { $0.id == id }) else { return }
        let change: (inout Event) -> Void = { e in
            guard e.kind == .todo else { return }
            if e.isDone {
                e.isDone = false; e.status = .active; e.completeAt = nil
            } else {
                e.isDone = true; e.status = .completed; e.completeAt = now
            }
        }
        if event.isRecurringSeries {
            let day = occurrenceDate ?? event.primaryTimeRange?.start ?? now
            _ = store.applyRecurringEdit(seriesID: id, occurrenceDate: day, scope: .single, now: now, edit: change)
        } else {
            var updated = event
            change(&updated)
            store.replaceCalendarEvent(updated, now: now)
        }
    }

    func returnToStack(id: UUID, now: Date) {
        // canReturnToStack excludes recurring, so this only ever runs on a
        // concrete row — no series routing needed.
        apply(id: id, now: now) { event in
            guard event.canReturnToStack else { return }
            event.timeRanges = []
        }
    }

    // MARK: - Repeat rule + scoped delete

    /// Change the repeat RULE of the selected series with an explicit scope
    /// (all events / this-and-following). Unlike field edits (which customize
    /// one occurrence), the rule is a series-level change the user must scope.
    ///
    /// KNOWN DEFERRAL (QA F3): turning a series OFF (unit `.none`, scope
    /// `.all`) leaves its already-materialized exception instances parented to
    /// the now-non-series row — they render as independent blocks on their
    /// days. What SHOULD happen to customized occurrences when a series loses
    /// its cadence (re-absorb / delete / keep) is a product decision, tracked
    /// for A1 follow-up; the current behavior (keep as standalone) is the
    /// least-destructive default.
    func applyRepeat(unit: Event.RepeatUnit, interval: Int,
                     endType: Event.RepeatEndType, endDate: Date?, endCount: Int?,
                     scope: Event.RecurrenceEditScope, now: Date) {
        guard let id = selectedID, let event else { return }
        let day = selectedOccurrenceDate ?? event.primaryTimeRange?.start ?? now
        let rule = RepeatRuleNormalizer.normalized(
            unit: unit, interval: interval, endType: endType,
            endDate: endDate, endCount: endCount, now: now, calendar: calendar
        )
        let newID = store.applyRecurringEdit(seriesID: id, occurrenceDate: day, scope: scope, now: now) { e in
            rule.apply(to: &e)
        }
        if scope == .following, let newID { select(newID, occurrenceDate: day) }
    }

    /// Delete the selection, scoped for a series (this / this-and-following /
    /// all) or a plain removal for a one-off.
    func deleteScoped(scope: Event.RecurrenceEditScope, now: Date) {
        guard let id = selectedID, let event else { return }
        if event.isRecurringSeries {
            let day = selectedOccurrenceDate ?? event.primaryTimeRange?.start ?? now
            store.removeRecurringOccurrence(seriesID: id, occurrenceDate: day, scope: scope, now: now)
        } else {
            store.removeCalendarEvent(id: id, now: now)
        }
        selectedID = nil
        selectedOccurrenceDate = nil
    }

    func delete(id: UUID, occurrenceDate: Date?, now: Date) {
        if let e = store.calendarEvents.first(where: { $0.id == id }), e.isRecurringSeries {
            // A context-menu delete on a series occurrence removes just that
            // day (the scope prompt lives in the inspector's Delete).
            let day = occurrenceDate ?? e.primaryTimeRange?.start ?? now
            store.removeRecurringOccurrence(seriesID: id, occurrenceDate: day, scope: .single, now: now)
        } else {
            store.removeCalendarEvent(id: id, now: now)
        }
        // Only the pane's own selection collapses; deleting some OTHER block
        // via the context menu must not tear down an open inspection (#1).
        if selectedID == id { selectedID = nil; selectedOccurrenceDate = nil }
    }

    // MARK: - Commit plumbing

    /// A field edit on a SERIES customizes one occurrence — materialize a
    /// `.single` exception and re-select it, so the pane now targets the
    /// concrete instance (matches iOS `editOccurrence`). A concrete row edits
    /// in place.
    private func apply(id: UUID, now: Date, _ change: (inout Event) -> Void) {
        guard let event = store.calendarEvents.first(where: { $0.id == id }) else { return }
        if event.isRecurringSeries {
            // No-op guard (QA F2): `Event.applyEdit(.single)` always forks an
            // exception before running the edit, so the store's array-equality
            // guard can't catch a field write that changes nothing (a new id
            // is always added). Detect the no-op here — re-tapping the current
            // type/effort must NOT silently detach the day from the series.
            var probe = event
            change(&probe)
            guard probe != event else { return }

            let day = selectedOccurrenceDate ?? event.primaryTimeRange?.start ?? now
            if let newID = store.applyRecurringEdit(
                seriesID: id, occurrenceDate: day, scope: .single, now: now, edit: change
            ) {
                // Re-select ONLY when this edit targets the pane's current
                // selection (review F1): a text field flushing on teardown
                // after the user clicked away or closed the pane must commit
                // its exception WITHOUT hijacking the new selection or
                // resurrecting a just-closed pane.
                if selectedID == id {
                    selectedID = newID
                    selectedOccurrenceDate = nil   // the exception is a concrete row now
                }
            }
        } else {
            var updated = event
            change(&updated)
            store.replaceCalendarEvent(updated, now: now)
        }
    }

    /// The Start picker RESIZES (keeps the end), symmetric with setEnd — two
    /// labeled pickers should both resize; moving the whole event when Start
    /// changes silently shifts the end and surprises the user (code-review
    /// F2). Start is clamped so the event keeps its 15-min minimum.
    func setStart(id: UUID, _ start: Date, now: Date) {
        applyTimed(id: id, now: now) { ranges in
            let end = ranges[0].end
            ranges[0] = Event.TimeRange(start: min(start, end.addingTimeInterval(-900)), end: end)
        }
    }

    func setEnd(id: UUID, _ end: Date, now: Date) {
        applyTimed(id: id, now: now) { ranges in
            let start = ranges[0].start
            ranges[0] = Event.TimeRange(start: start,
                                        end: max(end, start.addingTimeInterval(900)))
        }
    }

    /// Time edits fold into `apply` so a series occurrence materializes a
    /// single exception the same way. The exception the engine mints already
    /// carries the occurrence's range, so `renderTimeRanges` inside the edit
    /// closure reads that range and the picker adjusts it.
    private func applyTimed(id: UUID, now: Date,
                            _ change: (inout [Event.TimeRange]) -> Void) {
        // No-op guard in the OCCURRENCE frame: the generic `apply` probe
        // compares the SERIES template's day-0 range, which always differs
        // from an occurrence-day range, so a time picker reverted to the same
        // time would still mint a phantom exception (code-review F4). Check
        // the intended range against the occurrence's CURRENT range first.
        if let event = store.calendarEvents.first(where: { $0.id == id }),
           event.isRecurringSeries, let occ = occurrenceRange {
            var probe = [occ]
            change(&probe)
            guard probe != [occ] else { return }
        }
        apply(id: id, now: now) { event in
            var ranges = event.renderTimeRanges(calendar: calendar)
            if ranges.isEmpty {
                let start = calendar.startOfDay(for: now).addingTimeInterval(9 * 3600)
                ranges = [Event.TimeRange(start: start, end: start.addingTimeInterval(3600))]
            }
            change(&ranges)
            event.timeRanges = ranges
        }
    }

}
