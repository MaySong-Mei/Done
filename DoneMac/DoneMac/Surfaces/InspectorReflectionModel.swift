//
//  InspectorReflectionModel.swift
//  DoneMac
//
//  The phone detail's Reflection page, Mac-side: completion, effort,
//  emotion / behavior signals, the reflection note and the event's images —
//  all on the occurrence's log record (images on the event's intake), each
//  through the store call the phone's page makes:
//    completion → applyQuickCompletion, signals → applyQuickTagIntent
//    (intent + fresh read, gh#216), note → upsertSeededLogRecord coalesced
//    (gh#219's debounced commit, flushed when the pane goes away).
//

import Foundation
import Observation

@MainActor
@Observable
final class InspectorReflectionModel {
    let occurrence: CalendarEventOccurrenceContext

    @ObservationIgnored private let store: EventStore

    /// The note being typed. Loaded once from the record (the phone's
    /// loadDetailDraftIfNeeded); every change writes through.
    var noteText: String {
        didSet { if noteText != oldValue { saveNote() } }
    }

    init(occurrence: CalendarEventOccurrenceContext, store: EventStore) {
        self.occurrence = occurrence
        self.store = store
        self.noteText = store.prefilledDraft(for: occurrence).note
    }

    // MARK: - Reads (fresh from the record each time)

    private var draft: CalendarEventLogDraft { store.prefilledDraft(for: occurrence) }

    /// The phone shows "Completed" when nothing is recorded yet.
    var completionStatus: EventLogCompletionStatus { draft.completionStatus ?? .completed }
    var emotions: Set<String> { Set(draft.emotions) }
    var behaviors: Set<String> { Set(draft.behaviors) }

    // MARK: - Writes

    func setCompletion(_ status: EventLogCompletionStatus) {
        store.applyQuickCompletion(status, for: occurrence)
    }

    /// `targetSelected` is the user's intent judged from what they saw
    /// (the phone's quickTagPicker contract), not a computed set.
    func toggle(_ axis: CalendarQuickTagAxis, tagID: String, targetSelected: Bool) {
        store.applyQuickTagIntent(axis: axis, tagID: tagID, targetSelected: targetSelected, for: occurrence)
    }

    private func saveNote() {
        let trimmed = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        store.upsertSeededLogRecord(for: occurrence, coalesced: true) { $0.note = trimmed }
    }

    /// The pane is going away: land the debounced note commit now.
    func flush() {
        _ = store.flushPendingLogRecordCommit()
    }
}
