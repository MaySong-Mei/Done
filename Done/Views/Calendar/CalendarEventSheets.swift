//
//  CalendarEventSheets.swift
//  Done
//
//  Sheet views for creating and editing calendar events
//

import SwiftUI

struct CreateCalendarEventView: View {
    var timeRange: Event.TimeRange
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

    /// The draft may only fill a composer that opened empty — callers with
    /// their own prefill (reminder → event, agentic intake) always win.
    /// The caller's timeRange also always wins: a drag-created range is
    /// explicit intent, and the banner entry passes the draft's own range.
    private var restoredDraft: CalendarComposerDraft? {
        guard let storedDraft else { return nil }
        guard !CalendarComposerDraft.callerProvidedContent(
            initialTitle: initialTitle,
            initialNote: initialNote,
            initialLocation: initialLocation,
            hasAgenticIntake: preloadedAgenticIntake != nil
        ) else { return nil }
        return storedDraft
    }

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
            onScenePhaseDraft: { snapshot in
                // Meaningless snapshots (nothing typed) clear the slot — an
                // emptied form must not resurrect an older draft next open.
                if snapshot.isMeaningful {
                    CalendarComposerDraftStore.save(snapshot)
                } else {
                    CalendarComposerDraftStore.clear()
                }
            },
            onDraftSessionEnd: {
                CalendarComposerDraftStore.clear()
            }
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
    /// the edit draft. nil disables drafting for the session — recurring
    /// scope edits are never drafted (a scope-aware apply cannot be safely
    /// resumed against a series that may have mutated meanwhile).
    private let draftBase: CalendarComposerDraft?
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
        let draftable = !event.isRecurringSeries && recurrenceScope == nil
        let base = draftable ? CalendarComposerDraft.snapshot(of: event) : nil
        self.draftBase = base
        _restoredEdits = State(initialValue: base.flatMap {
            CalendarEditDraftStore.loadFresh(eventID: event.id, current: $0)
        })
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
            initialStartTime: restoredEdits?.startTime ?? event.timeRanges.first?.start ?? Date(),
            initialEndTime: restoredEdits?.endTime ?? event.timeRanges.first?.end ?? Date().addingTimeInterval(3600),
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
                    if snapshot.fieldsEqual(base) {
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
