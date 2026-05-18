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

extension EventStore {

    // MARK: - Feedback

    func feedbackRecord(for occurrence: CalendarEventOccurrenceContext) -> CalendarEventFeedbackRecord? {
        guard let event = findCalendarEvent(id: occurrence.eventID) else {
            return nil
        }
        let key = CalendarOccurrenceKey.make(for: event, occurrenceDate: occurrence.occurrenceDate)
        return calendarEventFeedbackRecords.first(where: { $0.id == key })
    }

    func upsertFeedbackRecord(
        for occurrence: CalendarEventOccurrenceContext,
        mutate: (inout CalendarEventFeedbackRecord) -> Void
    ) {
        guard let event = findCalendarEvent(id: occurrence.eventID) else { return }
        let now = Date()
        let key = CalendarOccurrenceKey.make(for: event, occurrenceDate: occurrence.occurrenceDate)

        if let index = calendarEventFeedbackRecords.firstIndex(where: { $0.id == key }) {
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
        guard let index = calendarEvents.firstIndex(where: { $0.id == eventID }) else { return }
        let targetColorDepth = Event.colorDepth(forEffort: effort)
        guard abs(calendarEvents[index].colorDepth - targetColorDepth) > 0.0001 else { return }
        var updatedEvent = calendarEvents[index]
        updatedEvent.colorDepth = targetColorDepth
        calendarEvents[index] = updatedEvent
        saveCalendarEvents(refreshInterrupts: false)
    }

    func logRecord(for occurrence: CalendarEventOccurrenceContext) -> CalendarEventLogRecord? {
        guard let key = calendarOccurrenceKey(for: occurrence) else { return nil }
        return calendarEventLogRecords.first(where: { $0.id == key })
    }

    func upsertLogRecord(
        for occurrence: CalendarEventOccurrenceContext,
        mutate: (inout CalendarEventLogRecord) -> Void
    ) {
        guard let event = findCalendarEvent(id: occurrence.eventID) else { return }
        let now = Date()
        let key = CalendarOccurrenceKey.make(for: event, occurrenceDate: occurrence.occurrenceDate)

        if let index = calendarEventLogRecords.firstIndex(where: { $0.id == key }) {
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
        if let record = calendarEventLogRecords.first(where: { $0.id == key }) {
            syncCalendarEventColorDepthIfNeeded(eventID: occurrence.eventID, effort: record.effort)
        }
        saveCalendarEventLogRecords()
        calendarEventLogChanged.send(occurrence)
    }

    // MARK: - Timeline Notes

    func appendTimelineNote(
        _ text: String,
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
              let index = calendarEventLogRecords.firstIndex(where: { $0.id == key }) else {
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
              let index = calendarEventLogRecords.firstIndex(where: { $0.id == key }) else {
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
        if let record = logRecord(for: occurrence) {
            return CalendarEventLogDraft(
                suggestedTemplateID: record.suggestedTemplateID.flatMap(EventLogTemplateID.init(rawValue:)),
                selectedTemplateID: record.selectedTemplateID.flatMap(EventLogTemplateID.init(rawValue:)),
                completionStatus: record.completionStatus,
                actualDurationMinutes: record.actualDurationMinutes,
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

        let occurrenceEvent = findCalendarEvent(id: occurrence.eventID)
        let defaultDurationMinutes = occurrenceEvent
            .flatMap { event in
                calendarOccurrenceDisplayRange(event: event, occurrenceDate: occurrence.occurrenceDate)
            }
            .map { max(1, Int($0.end.timeIntervalSince($0.start) / 60)) }

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
            if let index = calendarEventFeedbackRecords.firstIndex(where: { $0.id == key }) {
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

    /// Shared pruning logic for deleting records associated with a single calendar event.
    fileprivate func pruneRecords<T: OccurrenceRecord>(
        from records: inout [T],
        forDeletedEvent event: Event,
        save: () -> Void
    ) {
        let before = records.count
        let calendar = Calendar.current

        if event.isExceptionInstance, let parentID = event.recurrenceParentId {
            let occurrenceDay = calendar.startOfDay(
                for: event.recurrenceInstanceDate
                    ?? event.primaryTimeRange?.start
                    ?? Date.distantPast
            )
            records.removeAll { record in
                record.baseSeriesEventID == parentID
                    && calendar.isDate(record.occurrenceDate, inSameDayAs: occurrenceDay)
            }
        } else {
            records.removeAll { record in
                record.eventID == event.id || record.baseSeriesEventID == event.id
            }
        }

        if records.count != before {
            save()
        }
    }

    /// Shared pruning logic for deleting records associated with a recurring series.
    fileprivate func pruneRecords<T: OccurrenceRecord>(
        from records: inout [T],
        forDeletedRecurringSeries seriesEvent: Event,
        occurrenceDate: Date,
        scope: Event.RecurrenceEditScope,
        save: () -> Void
    ) {
        let before = records.count
        let calendar = Calendar.current
        let targetDay = calendar.startOfDay(for: occurrenceDate)
        let baseSeriesID = seriesEvent.id

        records.removeAll { record in
            guard record.baseSeriesEventID == baseSeriesID else { return false }
            switch scope {
            case .all:
                return true
            case .single:
                return calendar.isDate(record.occurrenceDate, inSameDayAs: targetDay)
            case .following:
                return record.occurrenceDate >= targetDay
            }
        }

        if records.count != before {
            save()
        }
    }

    func pruneFeedbackForDeletedCalendarEvent(_ event: Event) {
        pruneRecords(from: &calendarEventFeedbackRecords, forDeletedEvent: event, save: saveCalendarEventFeedbackRecords)
    }

    func pruneLogRecordsForDeletedCalendarEvent(_ event: Event) {
        pruneRecords(from: &calendarEventLogRecords, forDeletedEvent: event, save: saveCalendarEventLogRecords)
    }

    func pruneFeedbackForDeletedRecurringSeries(
        seriesEvent: Event,
        occurrenceDate: Date,
        scope: Event.RecurrenceEditScope
    ) {
        pruneRecords(from: &calendarEventFeedbackRecords, forDeletedRecurringSeries: seriesEvent, occurrenceDate: occurrenceDate, scope: scope, save: saveCalendarEventFeedbackRecords)
    }

    func pruneLogRecordsForDeletedRecurringSeries(
        seriesEvent: Event,
        occurrenceDate: Date,
        scope: Event.RecurrenceEditScope
    ) {
        pruneRecords(from: &calendarEventLogRecords, forDeletedRecurringSeries: seriesEvent, occurrenceDate: occurrenceDate, scope: scope, save: saveCalendarEventLogRecords)
    }

    // MARK: - Helpers

    fileprivate func calendarOccurrenceKey(for occurrence: CalendarEventOccurrenceContext) -> CalendarOccurrenceKey? {
        guard let event = findCalendarEvent(id: occurrence.eventID) else {
            return nil
        }
        return CalendarOccurrenceKey.make(for: event, occurrenceDate: occurrence.occurrenceDate)
    }
}
