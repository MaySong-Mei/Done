//
//  CalendarEventSheets.swift
//  Done
//
//  Sheet views for creating and editing calendar events
//

import SwiftUI

struct CreateCalendarEventView: View {
    var timeRange: Event.TimeRange
    /// True only when the user explicitly chose to resume the kill-rescue
    /// draft (the calendar-page banner). Plain create entries never
    /// auto-fill from the slot: a stale draft's folded-away fields (note,
    /// people, repeat) must not ride silently into an unrelated new event.
    var resumesDraft: Bool = false
    var initialTitle: String = ""
    var initialTypeTitle: String = "Study"
    var initialNote: String = ""
    var initialLocation: String = ""
    var preloadedAgenticIntake: AgenticIntakeRecord? = nil
    // gh#182: no default — a call site that forgets this parameter should
    // fail to compile, not silently bypass the "AI Type Suggestions"
    // setting the way other entry points did before this fix.
    var isTypeSuggestionEnabled: Bool
    var onCreated: ((Event) -> Void)? = nil
    /// Fires once the session's final write/clear has landed. The presenting
    /// page must refresh its rescue banner from HERE and not from the sheet's
    /// `onDismiss`: `onDismiss` runs BEFORE the form's `onDisappear`, so it
    /// reads the session's last continuous write rather than its settled
    /// state — which showed a phantom "resume" banner after Done/Cancel and
    /// hid the real one after a swipe-down inside the debounce window.
    var onDraftSlotSettled: (() -> Void)? = nil
    @EnvironmentObject private var store: EventStore

    private let typeInferenceService = CalendarEventTypeInferenceService()

    /// Loaded once at presentation time (@State keeps the value stable across
    /// body re-evaluations). Fresh-and-meaningful only; expired blobs are
    /// cleared inside loadFresh.
    @State private var storedDraft = CalendarComposerDraftStore.loadFresh()

    /// Whether this session owns the create-draft slot. Sessions opened with
    /// caller prefill (reminder → event, agentic intake) never touch it — in
    /// EITHER direction. They don't restore from it (the prefill is fresher
    /// intent), and symmetrically they must not write to or clear it: a
    /// prefilled session ending normally would otherwise destroy a rescue
    /// draft pending for the plain composer that this session never showed.
    private var usesDraftSlot: Bool {
        !CalendarComposerDraft.callerProvidedContent(
            initialTitle: initialTitle,
            initialNote: initialNote,
            initialLocation: initialLocation,
            hasAgenticIntake: preloadedAgenticIntake != nil
        )
    }

    /// The caller's timeRange always wins over the draft's: the banner entry
    /// passes the draft's own range itself.
    private var restoredDraft: CalendarComposerDraft? {
        guard resumesDraft, usesDraftSlot else { return nil }
        return storedDraft
    }

    /// Whether this session has written the slot — set by any continuous
    /// write, scene-departure flush or swipe-down flush that carried
    /// meaningful content. Sessions that neither resumed nor wrote the slot
    /// must not clear it on exit — a plain drag-create ending normally would
    /// otherwise destroy a rescue still waiting on the banner.
    @State private var wroteDraftSlot = false

    var body: some View {
        let draft = restoredDraft
        CalendarEventFormView(
            navigationTitle: L(.newEvent),
            initialTitle: draft?.title ?? initialTitle,
            initialKind: draft?.kind ?? .event,
            initialDeadline: draft?.deadline,
            initialTypeTitle: draft?.typeTitle ?? initialTypeTitle,
            initialNote: draft?.note ?? initialNote,
            initialLocation: draft?.location ?? initialLocation,
            initialStartTime: timeRange.start,
            initialEndTime: timeRange.end,
            initialIsAllDay: draft?.isAllDay ?? false,
            initialRepeatUnit: draft?.repeatUnit ?? .none,
            initialRepeatInterval: draft?.repeatInterval ?? 1,
            initialRepeatEndType: draft?.repeatEndType ?? .none,
            initialRepeatEndDate: draft?.repeatEndDate,
            initialRepeatEndCount: draft?.repeatEndCount,
            initialPeopleIDs: draft?.peopleIDs ?? [],
            agenticIntake: preloadedAgenticIntake,
            // gh#182: was hardcoded `true`, bypassing the "AI Type
            // Suggestions" toggle entirely for while-typing autocomplete.
            // `isTypeSuggestionEnabled` is this view's own settings-backed
            // property (see init), already threaded from the real
            // `calendarAgenticCreateEnabled` @AppStorage by both call sites
            // in CalendarPageView — same value the post-save inference call
            // below already respects.
            allowsAutomaticTypeSelection: isTypeSuggestionEnabled,
            onDraftSnapshot: usesDraftSlot ? { snapshot in
                applyCreateDraftAction(
                    calendarCreateDraftSlotAction(
                        snapshotIsMeaningful: snapshot.isMeaningful,
                        resumesDraft: resumesDraft,
                        wroteDraftSlot: wroteDraftSlot
                    ),
                    snapshot: snapshot
                )
            } : nil,
            // Always installed, including for prefill sessions: the policy
            // function already resolves those to `.leaveAlone`, and the hook
            // is what tells the presenting page the slot has settled.
            onDraftSessionEnd: { pendingSnapshot in
                applyCreateDraftAction(
                    calendarCreateDraftSessionEndAction(
                        pendingSnapshotIsMeaningful: pendingSnapshot?.isMeaningful,
                        usesDraftSlot: usesDraftSlot,
                        resumesDraft: resumesDraft,
                        wroteDraftSlot: wroteDraftSlot
                    ),
                    snapshot: pendingSnapshot
                )
                onDraftSlotSettled?()
            }
        ) { form in
            let event = EventLogTemplateAdvisor().applySuggestion(to: form.toEvent())
            store.addCalendarEvent(event)
            // The event is committed — consume the draft NOW rather than
            // leaning on `onDisappear` to clear it. Without this, a crash in
            // the gap between Done and teardown would leave a rescue for an
            // event that already exists, and accepting it would create a
            // duplicate.
            //
            // Routed through the same policy function as every other exit
            // rather than an inline condition: Done is just an explicit end,
            // and a session that never wrote the slot doesn't own what's in
            // it. A hand-rolled gate here previously cleared on
            // `usesDraftSlot` alone, which destroyed an untouched session's
            // pending rescue the moment the user pressed Done on an empty
            // form.
            applyCreateDraftAction(
                calendarCreateDraftSessionEndAction(
                    pendingSnapshotIsMeaningful: nil,
                    usesDraftSlot: usesDraftSlot,
                    resumesDraft: resumesDraft,
                    wroteDraftSlot: wroteDraftSlot
                ),
                snapshot: nil
            )
            onCreated?(event)
            Task { @MainActor in
                await typeInferenceService.inferTypeIfNeeded(
                    for: event,
                    savedForm: form,
                    isSuggestionEnabled: isTypeSuggestionEnabled,
                    store: store
                )
            }
        }
    }

    /// Carries out a slot action decided by `calendarCreateDraftSlotAction` /
    /// `calendarCreateDraftSessionEndAction`. All policy lives in those two
    /// pure functions; this is only the side effect.
    private func applyCreateDraftAction(
        _ action: CalendarComposerDraftSlotAction,
        snapshot: CalendarComposerDraft?
    ) {
        switch action {
        case .save:
            // Unreachable with a nil snapshot: `.save` requires a meaningful
            // one, and an explicit end supplies none. Assert rather than fail
            // quietly — silently skipping here would also skip the
            // `wroteDraftSlot` write, which would break every later ownership
            // decision, not just this one write.
            guard let snapshot else {
                assertionFailure("`.save` resolved without a snapshot — ownership tracking would desync")
                return
            }
            // Idempotent: the continuous write resolves to `.save` every
            // debounce cycle, and an unconditional assignment would invalidate
            // this view (and re-init the whole form) ~2.5×/second while typing.
            if !wroteDraftSlot { wroteDraftSlot = true }
            CalendarComposerDraftStore.save(snapshot)
        case .clear:
            CalendarComposerDraftStore.clear()
        case .leaveAlone:
            break
        }
    }
}

struct EditCalendarEventView: View {
    let event: Event
    let occurrenceDate: Date?
    let recurrenceScope: Event.RecurrenceEditScope?
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: EventStore
    @State private var showDeleteConfirmation = false

    /// The field snapshot this edit session started from, used to fingerprint
    /// the edit draft. @State so it FREEZES at first mount: the detail-page
    /// call site rebuilds this view from the live store on every parent
    /// invalidation, and a base recomputed after an external mutation
    /// (domino push, sync) would fingerprint stale edits as fresh — exactly
    /// the corruption the base exists to prevent. nil disables drafting —
    /// recurring scope edits are never drafted (a scope-aware apply cannot
    /// be safely resumed against a series that may have mutated meanwhile),
    /// and neither are rangeless events (their snapshot start/end fall back
    /// to wall-clock now, so no two fingerprints could ever match).
    @State private var draftBase: CalendarComposerDraft?
    /// Stashed edits from a killed session on this same event, valid only
    /// because the event still matches the draft's base (checked at init).
    @State private var restoredEdits: CalendarComposerDraft?

    init(
        event: Event,
        occurrenceDate: Date? = nil,
        recurrenceScope: Event.RecurrenceEditScope? = nil
    ) {
        self.event = event
        self.occurrenceDate = occurrenceDate
        self.recurrenceScope = recurrenceScope
        let draftable = !event.isRecurringSeries
            && recurrenceScope == nil
            && !event.timeRanges.isEmpty
        let base = draftable ? CalendarComposerDraft.snapshot(of: event) : nil
        _draftBase = State(initialValue: base)
        _restoredEdits = State(initialValue: base.flatMap {
            CalendarEditDraftStore.loadFresh(eventID: event.id, current: $0)
        })
    }

    /// For a recurring-series occurrence edit, seed the time from the day being
    /// edited (occurrenceDate at the series time), NOT the series' seed range.
    /// Otherwise `form.apply` would rewrite the materialized exception's
    /// timeRanges back to the seed day, relocating the occurrence and blanking
    /// the edited day.
    /// Only `.single` (exception) and `.following` (new split series) anchor to
    /// the edited day; `.all` edits the whole series and must keep the series
    /// seed range (else form.apply would move seriesStart forward and drop the
    /// earlier occurrences).
    ///
    /// The non-occurrence fallback reads `renderPrimaryTimeRange(calendar:)` —
    /// the same projection the canvas places the block with — never raw
    /// `timeRanges`. A detached exception instance's stored range can sit in
    /// its creation time zone while the canvas draws it projected onto the
    /// current frame; seeding from the raw value would show a time the block
    /// isn't drawn at. Leaving that wrong field untouched is harmless on its
    /// own for a SINGLE-range event — the seed round-trips bit-identical to
    /// `previous.timeRanges`, so `rebasedExceptionInstanceAfterRangeWrite`'s
    /// inequality guard never fires and nothing moves. (A multi-range
    /// traveled instance doesn't get the short-circuit either: `form.apply(to:)`
    /// writes this seed into element 0 and carries the rest of `event.timeRanges`
    /// through unchanged (gh#189), so the guard fires there even on an
    /// untouched edit — element 0 alone already differs from `previous`. The
    /// tail elements are unaffected by that: they're still literal keys in
    /// the guard's own projection map, so they land at their own
    /// projections regardless of why the guard fired.) The harm is TOUCHING
    /// it: an edit computed relative to the stale display commits a range
    /// that now differs from
    /// `previous` (the guard fires) but isn't a key in the guard's own
    /// projection map either — that map's keys are exactly
    /// `previous.timeRanges` — so it rides through unprojected while the
    /// mirror still gets moved onto the current frame underneath it, and the
    /// block visibly jumps to the mint-frame-anchored instant the edit was
    /// actually computed from (gh#152). For every other event this is
    /// identity: `renderTimeRanges` only transforms a detached instance
    /// whose mirror has drifted from the current frame, so ordinary events,
    /// series templates, and untraveled instances all fall through
    /// unchanged.
    ///
    /// Consequence for the traveled population: `form.apply` always rewrites
    /// `timeRanges` from this seed, so a title-only edit now commits the
    /// projection where it used to commit the identical raw value —
    /// `rebasedExceptionInstanceAfterRangeWrite` then normalizes the stored
    /// row and moves the mirror onto the current frame, a real write and
    /// sync push where before there was none. Accepted deliberately: it's
    /// the same normalization a drag would perform, it converges (the next
    /// edit reads identity, so it can't repeat), and "the user didn't touch
    /// the time field" isn't a signal this form tracks — inventing one just
    /// to suppress a write that only moves storage to match what the canvas
    /// already shows would be machinery in service of nothing.
    private var occurrenceSeedRange: Event.TimeRange {
        Self.occurrenceSeedRange(
            event: event,
            occurrenceDate: occurrenceDate,
            recurrenceScope: recurrenceScope
        )
    }
    private var occurrenceSeedStart: Date { occurrenceSeedRange.start }
    private var occurrenceSeedEnd: Date { occurrenceSeedRange.end }

    /// Pure form of the seed above, so the sheet's wiring — not just the
    /// model helpers it calls — is testable without driving SwiftUI.
    static func occurrenceSeedRange(
        event: Event,
        occurrenceDate: Date?,
        recurrenceScope: Event.RecurrenceEditScope?,
        calendar: Calendar = .current
    ) -> Event.TimeRange {
        let seedsFromOccurrence = occurrenceDate != nil
            && (recurrenceScope == .single || recurrenceScope == .following)
        if event.isRecurringSeries, seedsFromOccurrence, let occDate = occurrenceDate,
           let range = CalendarLayout.recurrenceOccurrence(for: event, on: occDate, calendar: calendar) {
            return range
        }
        if let range = event.renderPrimaryTimeRange(calendar: calendar) {
            return range
        }
        return Event.TimeRange(start: Date(), end: Date().addingTimeInterval(3600))
    }

    /// Occurrence anchor for the delete confirmation's whole-series fallback
    /// (no scope/occurrence context supplied). Render-frame, like every other
    /// route seed (gh#204): identity for the series templates that actually
    /// reach it — `deleteEvent()` guards on `isRecurringSeries`, which
    /// excludes detached instances — and pinned to the projection so the seed
    /// can never name a day the canvas doesn't draw if that population ever
    /// widens. Static so tests bind the real seed without driving SwiftUI.
    static func fallbackDeleteOccurrenceDate(
        for event: Event,
        calendar: Calendar = .current
    ) -> Date {
        event.renderPrimaryTimeRange(calendar: calendar)?.start ?? Date()
    }

    /// The afterCount the edit form is seeded with, in the meaning of THIS
    /// sheet's scope (gh#126). A `.following` edit makes the tapped occurrence
    /// the first occurrence of a newly split series, so "After N occurrences"
    /// must show — and edit — the split-off series' REMAINING count, not the
    /// original whole-series N. The sheet knows its scope at construction, so
    /// the seed can simply BE the right number: `form.apply` then re-stamps the
    /// value the user actually saw, with no restore guard in between.
    private var seededRepeatEndCount: Int? {
        restoredEdits?.repeatEndCount ?? Self.seededRepeatEndCount(
            event: event,
            occurrenceDate: occurrenceDate,
            recurrenceScope: recurrenceScope
        )
    }

    /// Pure form of the seed above (the draft-restore override aside), so the
    /// sheet's wiring — not just the model helper — is testable.
    static func seededRepeatEndCount(
        event: Event,
        occurrenceDate: Date?,
        recurrenceScope: Event.RecurrenceEditScope?,
        calendar: Calendar = .current
    ) -> Int? {
        Event.scopedRepeatEndCount(
            series: event,
            occurrenceDate: occurrenceDate,
            requestedScope: recurrenceScope,
            calendar: calendar
        )
    }

    /// The mutation this sheet's Save applies inside `applyRecurringEdit`, as a
    /// pure function of the submitted form — so what the sheet actually
    /// persists is testable without driving SwiftUI, and pairs with
    /// `seededRepeatEndCount` as the field's round trip.
    ///
    /// The `.afterCount` value rides straight through `form.apply`: it was
    /// SEEDED in this scope's meaning (for `.following`, the split-off series'
    /// remaining count), so re-stamping it writes exactly what `Event.applyEdit`
    /// computed when untouched and the user's own number when nudged — no
    /// restore guard in between, no jump by `elapsed` (gh#126).
    static func recurringEdit(
        form: CalendarEventFormData,
        scope: Event.RecurrenceEditScope,
        occurrenceDate: Date,
        advisor: EventLogTemplateAdvisor = EventLogTemplateAdvisor(),
        calendar: Calendar = .current
    ) -> (inout Event) -> Void {
        { instance in
            instance = form.apply(to: instance)
            // A single-occurrence exception is a one-off — form.apply stamped
            // the series' repeat fields onto it; clear them so it can't carry a
            // stray rule. ONLY for `.single`: `.all` edits the whole series and
            // `.following` the new split series, and clearing their repeat
            // fields would collapse the recurrence.
            if scope == .single {
                // Strip repeat fields (an exception is a one-off) and lock it to
                // the edited day — the sheet's date picker could otherwise
                // relocate it without excepting the new day (double-render +
                // mis-keyed instanceDate).
                instance = Event.normalizedSingleOccurrenceException(
                    instance,
                    lockedTo: occurrenceDate,
                    calendar: calendar
                )
            }
            if instance.agenticIntake?.processingPhase == .failed {
                instance.agenticIntake?.processingPhase = .completed
                instance.agenticIntake?.failureMessage = nil
            }
            instance = advisor.applySuggestion(to: instance)
        }
    }

    var body: some View {
        CalendarEventFormView(
            navigationTitle: "Edit Event",
            initialTitle: restoredEdits?.title ?? event.title,
            initialKind: restoredEdits?.kind ?? event.kind,
            initialDeadline: restoredEdits != nil ? restoredEdits?.deadline : event.deadline,
            initialTypeTitle: restoredEdits?.typeTitle ?? event.type,
            initialNote: restoredEdits?.note ?? event.note,
            initialLocation: restoredEdits?.location ?? event.location,
            initialStartTime: restoredEdits?.startTime ?? occurrenceSeedStart,
            initialEndTime: restoredEdits?.endTime ?? occurrenceSeedEnd,
            initialIsAllDay: restoredEdits?.isAllDay ?? event.isAllDay,
            initialRepeatUnit: restoredEdits?.repeatUnit ?? event.repeatUnit,
            initialRepeatInterval: restoredEdits?.repeatInterval ?? event.repeatInterval,
            initialRepeatEndType: restoredEdits?.repeatEndType ?? event.repeatEndType,
            initialRepeatEndDate: restoredEdits != nil ? restoredEdits?.repeatEndDate : event.repeatEndDate,
            initialRepeatEndCount: seededRepeatEndCount,
            initialPeopleIDs: restoredEdits?.peopleIDs ?? event.peopleIDs ?? [],
            agenticIntake: event.agenticIntake,
            onDraftSnapshot: draftBase.map { base in
                { snapshot in
                    // The form's onAppear coerces an empty type to a fallback
                    // template; compare against the coerced value so that
                    // cosmetic rewrite doesn't read as a user edit.
                    var comparableBase = base
                    if comparableBase.typeTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        comparableBase.typeTitle = snapshot.typeTitle
                    }
                    if snapshot.fieldsEqual(comparableBase) {
                        // Nothing actually changed — no rescue needed, and a
                        // no-op draft must not shadow a real one later.
                        CalendarEditDraftStore.clear(eventID: event.id)
                    } else {
                        CalendarEditDraftStore.save(CalendarEditDraft(
                            eventID: event.id,
                            base: base,
                            edited: snapshot,
                            savedAt: Date()
                        ))
                    }
                }
            },
            onDraftSessionEnd: draftBase == nil ? nil : { _ in
                // Deliberately ignores the ambiguous-dismissal snapshot the
                // create slot honors. An edit draft restores SILENTLY on the
                // next open of this event — there's no banner to opt into —
                // so resurrecting edits the user swiped away would re-apply
                // changes they believe are abandoned, and a delete would
                // leave a rescue for a row that no longer exists. Every
                // dismissal clears here; the continuous write above still
                // covers the case this draft exists for, process death.
                CalendarEditDraftStore.clear(eventID: event.id)
            },
            onDeleteRequest: {
                showDeleteConfirmation = true
            }
        ) { form in
            let advisor = EventLogTemplateAdvisor()
            if event.isRecurringSeries, let scope = recurrenceScope, let occDate = occurrenceDate {
                store.applyRecurringEdit(
                    seriesEvent: event,
                    occurrenceDate: occDate,
                    scope: scope,
                    edit: Self.recurringEdit(
                        form: form,
                        scope: scope,
                        occurrenceDate: occDate,
                        advisor: advisor
                    )
                )
            } else {
                var updated = form.apply(to: event)
                if updated.agenticIntake?.processingPhase == .failed {
                    updated.agenticIntake?.processingPhase = .completed
                    updated.agenticIntake?.failureMessage = nil
                }
                store.updateCalendarEvent(advisor.applySuggestion(to: updated))
            }
        }
        .alert(L(.deleteEvent), isPresented: $showDeleteConfirmation) {
            Button(L(.cancel), role: .cancel) { }
            Button(L(.delete), role: .destructive) {
                deleteEvent()
            }
        } message: {
            Text(deleteConfirmationMessage)
        }
    }
}

private extension EditCalendarEventView {
    var resolvedRecurringDeleteScope: Event.RecurrenceEditScope {
        guard event.isRecurringSeries,
              recurrenceScope != nil,
              occurrenceDate != nil
        else {
            return .all
        }
        return recurrenceScope ?? .all
    }

    var deleteConfirmationMessage: String {
        guard event.isRecurringSeries else {
            return L(.deleteConfirmAll)
        }

        switch resolvedRecurringDeleteScope {
        case .single:
            return L(.deleteConfirmSingle)
        case .following:
            return L(.deleteConfirmFollowing)
        case .all:
            return L(.deleteConfirmAllSeries)
        }
    }

    func deleteEvent() {
        if event.isRecurringSeries {
            if let scope = recurrenceScope, let occurrenceDate {
                store.deleteRecurringCalendarEvent(
                    seriesEvent: event,
                    occurrenceDate: occurrenceDate,
                    scope: scope
                )
            } else {
                store.deleteRecurringCalendarEvent(
                    seriesEvent: event,
                    occurrenceDate: Self.fallbackDeleteOccurrenceDate(for: event),
                    scope: .all
                )
            }
        } else {
            store.deleteCalendarEvent(event)
        }
        dismiss()
    }
}
