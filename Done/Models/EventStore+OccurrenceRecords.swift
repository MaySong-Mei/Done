//
//  EventStore+OccurrenceRecords.swift
//  Done
//
//  Calendar event feedback + log records (occurrence-scoped), timeline notes,
//  chat-conversation linking, and generic pruning for both record kinds.
//  Split out of EventStore.swift on 2026-05-19.
//

import Foundation
import Combine
import os

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Done",
    category: "EventStore"
)

extension EventStore {

    // MARK: - Feedback

    func feedbackRecord(for occurrence: CalendarEventOccurrenceContext) -> CalendarEventFeedbackRecord? {
        guard let event = findCalendarEvent(id: occurrence.eventID) else {
            return nil
        }
        let key = CalendarOccurrenceKey.make(for: event, occurrenceDate: occurrence.occurrenceDate)
        return feedbackRecordIndex(id: key).map { calendarEventFeedbackRecords[$0] }
    }

    func upsertFeedbackRecord(
        for occurrence: CalendarEventOccurrenceContext,
        mutate: (inout CalendarEventFeedbackRecord) -> Void
    ) {
        guard let event = findCalendarEvent(id: occurrence.eventID) else { return }
        let now = Date()
        let key = CalendarOccurrenceKey.make(for: event, occurrenceDate: occurrence.occurrenceDate)

        if let index = feedbackRecordIndex(id: key) {
            mutate(&calendarEventFeedbackRecords[index])
            calendarEventFeedbackRecords[index].updatedAt = now
        } else {
            let day = Calendar.current.startOfDay(for: occurrence.occurrenceDate)
            var record = CalendarEventFeedbackRecord(
                id: key,
                eventID: event.id,
                baseSeriesEventID: key.baseSeriesEventID,
                occurrenceDate: day,
                createdAt: now,
                updatedAt: now
            )
            mutate(&record)
            record.updatedAt = now
            calendarEventFeedbackRecords.append(record)
        }
        saveCalendarEventFeedbackRecords()
        calendarEventFeedbackChanged.send(occurrence)
    }

    // MARK: - Log

    /// Mirrors the latest log effort onto the calendar event's `colorDepth`
    /// so the calendar block tint stays in sync. Called from upsertLogRecord.
    fileprivate func syncCalendarEventColorDepthIfNeeded(eventID: UUID, effort: Int?) {
        guard let index = calendarEventIndex(id: eventID) else { return }
        let targetColorDepth = Event.colorDepth(forEffort: effort)
        guard abs(rawCalendarEvents[index].colorDepth - targetColorDepth) > 0.0001 else { return }
        var updatedEvent = rawCalendarEvents[index]
        updatedEvent.colorDepth = targetColorDepth
        rawCalendarEvents[index] = updatedEvent
        saveCalendarEvents(refreshInterrupts: false)
    }

    func logRecord(for occurrence: CalendarEventOccurrenceContext) -> CalendarEventLogRecord? {
        guard let key = calendarOccurrenceKey(for: occurrence) else { return nil }
        return logRecordIndex(id: key).map { calendarEventLogRecords[$0] }
    }

    // MARK: - Interrupt durations

    /// Time ranges of the embedded interrupt children recorded against an
    /// occurrence's log, resolved from its `interruptRef` timeline items —
    /// the same refs `createInterrupt(...)` appends. Only `.embedded`
    /// children count: a detached/orphaned interrupt is no longer inside the
    /// parent window and must not subtract time.
    func embeddedInterruptChildRanges(
        for occurrence: CalendarEventOccurrenceContext
    ) -> [Event.TimeRange] {
        guard let record = logRecord(for: occurrence) else { return [] }
        return record.timelineItems
            .compactMap(\.interruptReferenceValue)
            .compactMap { reference -> Event.TimeRange? in
                guard let child = findCalendarEvent(id: reference.childEventID),
                      child.interruptRelation?.state == .embedded else { return nil }
                return child.primaryTimeRange
            }
    }

    /// Full / interrupt / net duration for an occurrence, subtracting embedded
    /// interrupt children (clamped to the parent range and merged). Returns
    /// `nil` when the occurrence has no resolvable range (e.g. a recurrence
    /// exception on the wrong day).
    func interruptedDuration(
        for event: Event,
        occurrenceDate: Date
    ) -> Event.InterruptedDuration? {
        guard let parentRange = calendarOccurrenceDisplayRange(
            event: event,
            occurrenceDate: occurrenceDate
        ) else { return nil }
        let context = CalendarEventOccurrenceContext(
            eventID: event.id,
            occurrenceDate: occurrenceDate,
            occurrenceID: nil,
            isAllDay: event.isAllDay,
            source: .timelineTap
        )
        return Event.interruptedDuration(
            parentRange: parentRange,
            childRanges: embeddedInterruptChildRanges(for: context)
        )
    }

    func upsertLogRecord(
        for occurrence: CalendarEventOccurrenceContext,
        mutate: (inout CalendarEventLogRecord) -> Void
    ) {
        guard let event = findCalendarEvent(id: occurrence.eventID) else {
            // Silent-drop diagnostic: every note/effort/tag write funnels
            // through here, and a miss (deleted event, stale occurrence
            // context) discards it with no UI signal. If "my note didn't
            // save" reports persist, this line is the first thing to check.
            logger.error("upsertLogRecord dropped write: event \(occurrence.eventID, privacy: .public) not in rawCalendarEvents (source: \(occurrence.source.rawValue, privacy: .public))")
            return
        }
        let now = Date()
        let key = CalendarOccurrenceKey.make(for: event, occurrenceDate: occurrence.occurrenceDate)

        if let index = logRecordIndex(id: key) {
            mutate(&calendarEventLogRecords[index])
            calendarEventLogRecords[index].updatedAt = now
        } else {
            let day = Calendar.current.startOfDay(for: occurrence.occurrenceDate)
            var record = CalendarEventLogRecord(
                id: key,
                eventID: event.id,
                baseSeriesEventID: key.baseSeriesEventID,
                occurrenceDate: day,
                suggestedTemplateID: event.suggestedLogTemplateID,
                createdAt: now,
                updatedAt: now
            )
            mutate(&record)
            record.updatedAt = now
            calendarEventLogRecords.append(record)
        }
        if let record = logRecordIndex(id: key).map({ calendarEventLogRecords[$0] }) {
            syncCalendarEventColorDepthIfNeeded(eventID: occurrence.eventID, effort: record.effort)
        }
        saveCalendarEventLogRecords()
        calendarEventLogChanged.send(occurrence)
    }

    // MARK: - Timeline Notes

    func appendTimelineNote(
        _ text: String,
        id: UUID = UUID(),
        createdAt: Date = Date(),
        source: String,
        images: [AgenticIntakeImageRef] = [],
        for occurrence: CalendarEventOccurrenceContext
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !images.isEmpty else { return }
        upsertLogRecord(for: occurrence) { record in
            record.timelineItems.append(
                .note(
                    EventLogTimelineNote(
                        id: id,
                        text: trimmed,
                        createdAt: createdAt,
                        source: source,
                        images: images
                    )
                )
            )
            record.timelineItems.sort { $0.createdAt > $1.createdAt }
        }
    }

    func updateTimelineNote(
        _ noteID: UUID,
        text: String,
        images: [AgenticIntakeImageRef]? = nil,
        for occurrence: CalendarEventOccurrenceContext
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !(images ?? []).isEmpty,
              let key = calendarOccurrenceKey(for: occurrence),
              let index = logRecordIndex(id: key) else {
            return
        }

        var didUpdate = false
        calendarEventLogRecords[index].timelineItems = calendarEventLogRecords[index].timelineItems.map { item in
            guard case .note(var note) = item, note.id == noteID else {
                return item
            }
            note.text = trimmed
            if let images {
                note.images = images
            }
            didUpdate = true
            return .note(note)
        }

        guard didUpdate else { return }
        calendarEventLogRecords[index].updatedAt = Date()
        saveCalendarEventLogRecords()
    }

    func deleteTimelineNote(
        _ noteID: UUID,
        for occurrence: CalendarEventOccurrenceContext
    ) {
        guard let key = calendarOccurrenceKey(for: occurrence),
              let index = logRecordIndex(id: key) else {
            return
        }
        calendarEventLogRecords[index].timelineItems.removeAll { item in
            item.noteValue?.id == noteID
        }
        calendarEventLogRecords[index].updatedAt = Date()
        saveCalendarEventLogRecords()
    }

    // MARK: - Log Record Lifecycle

    func deleteLogRecord(for occurrence: CalendarEventOccurrenceContext) {
        guard let key = calendarOccurrenceKey(for: occurrence) else { return }
        let before = calendarEventLogRecords.count
        calendarEventLogRecords.removeAll { $0.id == key }
        if calendarEventLogRecords.count != before {
            saveCalendarEventLogRecords()
            calendarEventLogChanged.send(occurrence)
        }
    }

    func prefilledDraft(for occurrence: CalendarEventOccurrenceContext) -> CalendarEventLogDraft {
        onPrefilledDraftComputed?(occurrence)
        let occurrenceEvent = findCalendarEvent(id: occurrence.eventID)

        // Decision: the logged "actual" duration defaults to NET active time
        // (scheduled minus embedded interrupts), not the full booked slot — an
        // interrupted block didn't run for its whole window, and the log
        // records what actually happened. Users can still edit it.
        let defaultDurationMinutes = occurrenceEvent
            .flatMap { interruptedDuration(for: $0, occurrenceDate: occurrence.occurrenceDate) }
            .map { max(1, $0.netMinutes) }

        if let record = logRecord(for: occurrence) {
            return CalendarEventLogDraft(
                suggestedTemplateID: record.suggestedTemplateID.flatMap(EventLogTemplateID.init(rawValue:)),
                selectedTemplateID: record.selectedTemplateID.flatMap(EventLogTemplateID.init(rawValue:)),
                completionStatus: record.completionStatus,
                // Fall back to net when the user hasn't recorded a duration yet,
                // so the editor opens pre-filled with active (not scheduled) time.
                actualDurationMinutes: record.actualDurationMinutes ?? defaultDurationMinutes,
                summary: record.summary,
                note: record.note,
                effort: record.effort,
                emotions: record.emotions,
                behaviors: record.behaviors,
                templateAnswers: record.templateAnswers,
                timelineNotes: record.timelineItems
                    .compactMap(\.noteValue)
                    .sorted { $0.createdAt > $1.createdAt }
            )
        }

        if let legacy = feedbackRecord(for: occurrence) {
            return CalendarEventLogDraft(
                suggestedTemplateID: occurrenceEvent
                    .flatMap { $0.suggestedLogTemplateID }
                    .flatMap(EventLogTemplateID.init(rawValue:)),
                selectedTemplateID: nil,
                completionStatus: nil,
                actualDurationMinutes: defaultDurationMinutes,
                summary: "",
                note: legacy.selfNote,
                effort: legacy.effort,
                emotions: legacy.emotions,
                behaviors: legacy.behaviors,
                templateAnswers: [:],
                timelineNotes: legacy.logs
                    .map { EventLogTimelineNote(id: $0.id, text: $0.text, createdAt: $0.createdAt, source: $0.source) }
                    .sorted { $0.createdAt > $1.createdAt }
            )
        }

        return CalendarEventLogDraft(
            suggestedTemplateID: occurrenceEvent
                .flatMap { $0.suggestedLogTemplateID }
                .flatMap(EventLogTemplateID.init(rawValue:)),
            selectedTemplateID: nil,
            completionStatus: nil,
            actualDurationMinutes: defaultDurationMinutes,
            summary: "",
            note: "",
            effort: nil,
            emotions: [],
            behaviors: [],
            templateAnswers: [:],
            timelineNotes: []
        )
    }

    func setChatConversationID(
        _ conversationID: UUID?,
        for occurrence: CalendarEventOccurrenceContext
    ) {
        if conversationID == nil,
           let event = findCalendarEvent(id: occurrence.eventID) {
            let key = CalendarOccurrenceKey.make(for: event, occurrenceDate: occurrence.occurrenceDate)
            if let index = feedbackRecordIndex(id: key) {
                calendarEventFeedbackRecords[index].chatConversationID = nil
                calendarEventFeedbackRecords[index].updatedAt = Date()
                saveCalendarEventFeedbackRecords()
                return
            }
        }
        upsertFeedbackRecord(for: occurrence) { record in
            record.chatConversationID = conversationID
        }
    }

    // MARK: - Generic Record Pruning

    /// The records that SURVIVE deleting `event`, or `nil` when none matched.
    ///
    /// Pure, and returning a value rather than taking the store's array
    /// `inout`, because the previous shape did not actually persist.
    /// `calendarEventLogRecords` is `@Published`, i.e. a computed property, so
    /// `inout` is copy-in/copy-out: the `save()` called from INSIDE ran before
    /// the writeback and therefore re-encoded the PRE-prune array. That payload
    /// is byte-identical to what is already on disk, `DurableEventStorage`
    /// skips identical commits, and the prune reached disk only if some later,
    /// unrelated write to the same slot happened to carry it. A kill in between
    /// resurrected the records of a deleted event on the next launch — the same
    /// "state no user action asked for" this issue is about.
    ///
    /// Assign first, commit second. With a return value that is the only order
    /// a caller can write.
    static func recordsSurviving<T: OccurrenceRecord>(
        _ records: [T],
        afterDeleting event: Event
    ) -> [T]? {
        var survivors = records

        if event.isExceptionInstance, let parentID = event.recurrenceParentId {
            // Which day's records does deleting this detached instance own?
            // Its NOMINAL day key — the identity every other classification
            // site compares (gh#127 item 1) — projected into the record day
            // system: current-frame midnight of the nominal day, reduced by
            // the frozen reference `dayKey`, exactly the reduction
            // `CalendarOccurrenceKey.make` applies to the canvas' lookup
            // dates. The previous `Calendar.current.startOfDay(mirror)` +
            // `isDate` read drifted one day after a tz change, so deleting
            // the instance pruned the NEIGHBORING day's records (permanent
            // loss of a surviving occurrence's logged history — the
            // direction gh#145 forbids) while the instance's own records
            // leaked (gh#127 review finding 5).
            let calendar = Calendar.current
            let instanceKey = Event.resolvedRecurrenceInstanceDayKey(
                dayKey: event.recurrenceInstanceDayKey,
                legacyDate: event.recurrenceInstanceDate
            ) ?? (event.primaryTimeRange?.start).map {
                Event.recurrenceDayKey(for: $0, calendar: calendar)
            }
            if let instanceKey,
               let nominalDay = CalendarOccurrenceKey.dayStart(forDayKey: instanceKey, in: calendar) {
                let recordDayKey = CalendarOccurrenceKey.dayKey(from: nominalDay)
                survivors.removeAll { record in
                    record.baseSeriesEventID == parentID
                        && record.id.dayKey == recordDayKey
                }
            }
        } else {
            survivors.removeAll { record in
                record.eventID == event.id || record.baseSeriesEventID == event.id
            }
        }

        return survivors.count == records.count ? nil : survivors
    }

    /// The recurring-series counterpart; same contract as the overload above.
    ///
    /// Day classification uses the SAME day system as the split reindex
    /// (`EventStore.reindexOccurrenceRecords`): each record's frozen
    /// `CalendarOccurrenceKey.dayKey` against the target day's key. The record's
    /// wall-clock `occurrenceDate` is a reference-tz midnight written by
    /// `CalendarOccurrenceKey.make`, so a raw `Calendar.current` comparison
    /// drifts by a day whenever the frozen reference tz and the device tz
    /// disagree — delete-`.following` would then classify the exact boundary
    /// record differently from edit-`.following`, and a wrong prune is
    /// permanent loss of logged history (gh#127-item4 consistency).
    static func recordsSurviving<T: OccurrenceRecord>(
        _ records: [T],
        afterDeletingSeries seriesEvent: Event,
        occurrenceDate: Date,
        scope: Event.RecurrenceEditScope
    ) -> [T]? {
        // Threshold from the current-tz MIDNIGHT of the target day — the same
        // projection record lookups use (`make` receives the canvas'
        // `Calendar.current.startOfDay` dates), so the prune removes exactly
        // the records that the deleted days would have looked up.
        let targetDayKey = CalendarOccurrenceKey.dayKey(
            from: Calendar.current.startOfDay(for: occurrenceDate)
        )
        let baseSeriesID = seriesEvent.id
        var survivors = records

        survivors.removeAll { record in
            guard record.baseSeriesEventID == baseSeriesID else { return false }
            switch scope {
            case .all:
                return true
            case .single:
                return record.id.dayKey == targetDayKey
            case .following:
                return record.id.dayKey >= targetDayKey
            }
        }

        return survivors.count == records.count ? nil : survivors
    }

    /// Each of these returns whether the slot is durable afterwards: `true`
    /// when nothing needed pruning, `true` when the prune committed, `false`
    /// when the commit failed. The delete paths chain these results — a delete
    /// only unlinks image files once every slot it had to write said yes
    /// (issue #145).
    @discardableResult
    func pruneFeedbackForDeletedCalendarEvent(_ event: Event) -> Bool {
        guard let survivors = EventStore.recordsSurviving(
            calendarEventFeedbackRecords, afterDeleting: event
        ) else { return true }
        calendarEventFeedbackRecords = survivors
        return saveCalendarEventFeedbackRecords()
    }

    @discardableResult
    func pruneLogRecordsForDeletedCalendarEvent(_ event: Event) -> Bool {
        guard let survivors = EventStore.recordsSurviving(
            calendarEventLogRecords, afterDeleting: event
        ) else { return true }
        calendarEventLogRecords = survivors
        return saveCalendarEventLogRecords()
    }

    @discardableResult
    func pruneFeedbackForDeletedRecurringSeries(
        seriesEvent: Event,
        occurrenceDate: Date,
        scope: Event.RecurrenceEditScope
    ) -> Bool {
        guard let survivors = EventStore.recordsSurviving(
            calendarEventFeedbackRecords,
            afterDeletingSeries: seriesEvent,
            occurrenceDate: occurrenceDate,
            scope: scope
        ) else { return true }
        calendarEventFeedbackRecords = survivors
        return saveCalendarEventFeedbackRecords()
    }

    @discardableResult
    func pruneLogRecordsForDeletedRecurringSeries(
        seriesEvent: Event,
        occurrenceDate: Date,
        scope: Event.RecurrenceEditScope
    ) -> Bool {
        guard let survivors = EventStore.recordsSurviving(
            calendarEventLogRecords,
            afterDeletingSeries: seriesEvent,
            occurrenceDate: occurrenceDate,
            scope: scope
        ) else { return true }
        calendarEventLogRecords = survivors
        return saveCalendarEventLogRecords()
    }

    // MARK: - Helpers

    fileprivate func calendarOccurrenceKey(for occurrence: CalendarEventOccurrenceContext) -> CalendarOccurrenceKey? {
        guard let event = findCalendarEvent(id: occurrence.eventID) else {
            return nil
        }
        return CalendarOccurrenceKey.make(for: event, occurrenceDate: occurrence.occurrenceDate)
    }
}
