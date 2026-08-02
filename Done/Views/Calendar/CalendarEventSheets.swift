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
    var isTypeSuggestionEnabled: Bool = true
    var onCreated: ((Event) -> Void)? = nil
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

    /// Whether this session has written the slot (a scene departure with
    /// meaningful content). Sessions that neither resumed nor wrote the slot
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
            allowsAutomaticTypeSelection: true,
            onScenePhaseDraft: usesDraftSlot ? { snapshot in
                if snapshot.isMeaningful {
                    wroteDraftSlot = true
                    CalendarComposerDraftStore.save(snapshot)
                } else if resumesDraft || wroteDraftSlot {
                    // An emptied form must not resurrect a draft this
                    // session owns — but an untouched session's flap must
                    // not clear a rescue it never displayed.
                    CalendarComposerDraftStore.clear()
                }
            } : nil,
            onDraftSessionEnd: (resumesDraft || usesDraftSlot) ? {
                // Only a session that consumed the slot (banner resume) or
                // wrote it may clear it on exit.
                if resumesDraft || wroteDraftSlot {
                    CalendarComposerDraftStore.clear()
                }
            } : nil
        ) { form in
            let event = EventLogTemplateAdvisor().applySuggestion(to: form.toEvent())
            store.addCalendarEvent(event)
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
    private var occurrenceSeedStart: Date {
        if event.isRecurringSeries, let occDate = occurrenceDate,
           let range = CalendarLayout.recurrenceOccurrence(for: event, on: occDate) {
            return range.start
        }
        return event.timeRanges.first?.start ?? Date()
    }
    private var occurrenceSeedEnd: Date {
        if event.isRecurringSeries, let occDate = occurrenceDate,
           let range = CalendarLayout.recurrenceOccurrence(for: event, on: occDate) {
            return range.end
        }
        return event.timeRanges.first?.end ?? Date().addingTimeInterval(3600)
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
            initialRepeatEndCount: restoredEdits?.repeatEndCount ?? event.repeatEndCount,
            initialPeopleIDs: restoredEdits?.peopleIDs ?? event.peopleIDs ?? [],
            agenticIntake: event.agenticIntake,
            onScenePhaseDraft: draftBase.map { base in
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
            onDraftSessionEnd: draftBase == nil ? nil : {
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
                    scope: scope
                ) { instance in
                    instance = form.apply(to: instance)
                    // A single-occurrence exception is a one-off, not a series —
                    // form.apply stamped the series' repeat fields onto it; clear
                    // them so the instance can't carry a stray recurrence rule.
                    instance.repeatUnit = .none
                    instance.repeatInterval = 1
                    instance.repeatEndType = .none
                    instance.repeatEndDate = nil
                    instance.repeatEndCount = nil
                    if instance.agenticIntake?.processingPhase == .failed {
                        instance.agenticIntake?.processingPhase = .completed
                        instance.agenticIntake?.failureMessage = nil
                    }
                    instance = advisor.applySuggestion(to: instance)
                }
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
                    occurrenceDate: event.primaryTimeRange?.start ?? Date(),
                    scope: .all
                )
            }
        } else {
            store.deleteCalendarEvent(event)
        }
        dismiss()
    }
}
