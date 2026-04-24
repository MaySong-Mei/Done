//
//  EventStore.swift
//  Done
//
//  Created by Shiqi Liu on 1/12/26.
//

import Foundation
import Combine
import WidgetKit

/// Protocol unifying CalendarEventFeedbackRecord and CalendarEventLogRecord
/// for shared pruning logic.
protocol OccurrenceRecord {
    var eventID: UUID { get }
    var baseSeriesEventID: UUID? { get }
    var occurrenceDate: Date { get }
}

extension CalendarEventFeedbackRecord: OccurrenceRecord {}
extension CalendarEventLogRecord: OccurrenceRecord {}

struct SmartSplitUndoInfo {
    let originalEvent: Event
    let newEventIDs: [UUID]
}

struct MergeUndoInfo {
    let sourceEvent: Event
    let targetEvent: Event
    let mergedEventID: UUID
}

@MainActor
final class EventStore: ObservableObject {
    @Published private(set) var events: [Event] = []
    @Published private(set) var calendarEvents: [Event] = []
    @Published private(set) var calendarEventFeedbackRecords: [CalendarEventFeedbackRecord] = []
    @Published private(set) var calendarEventLogRecords: [CalendarEventLogRecord] = []
    @Published private(set) var todoLists: [TodoList] = []

    let calendarEventRecorded = PassthroughSubject<Event, Never>()
    let calendarEventLogChanged = PassthroughSubject<CalendarEventOccurrenceContext, Never>()
    let calendarEventFeedbackChanged = PassthroughSubject<CalendarEventOccurrenceContext, Never>()

    private let storageKey = "events"
    private let calendarStorageKey = "calendarEvents"
    private let calendarEventFeedbackStorageKey = "calendarEventFeedbackRecords"
    private let calendarEventLogStorageKey = "calendarEventLogRecords"
    private let todoListsStorageKey = "todoLists"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    func load() {
        if let data = defaults.data(forKey: storageKey) {
            do {
                let decoded = try JSONDecoder().decode([Event].self, from: data)
                events = decoded
            } catch {
                events = []
            }
        } else {
            events = []
        }

        if let calData = defaults.data(forKey: calendarStorageKey) {
            do {
                calendarEvents = try JSONDecoder().decode([Event].self, from: calData)
            } catch {
                calendarEvents = []
            }
        }

        if let feedbackData = defaults.data(forKey: calendarEventFeedbackStorageKey) {
            do {
                calendarEventFeedbackRecords = try JSONDecoder().decode([CalendarEventFeedbackRecord].self, from: feedbackData)
            } catch {
                calendarEventFeedbackRecords = []
            }
        }

        if let logData = defaults.data(forKey: calendarEventLogStorageKey) {
            do {
                calendarEventLogRecords = try JSONDecoder().decode([CalendarEventLogRecord].self, from: logData)
            } catch {
                calendarEventLogRecords = []
            }
        }

        if let listData = defaults.data(forKey: todoListsStorageKey) {
            do {
                todoLists = try JSONDecoder().decode([TodoList].self, from: listData)
            } catch {
                todoLists = []
            }
        }

        migrateOrphanEvents()
        syncWidgetSnapshots()
    }

    private func migrateOrphanEvents() {
        let orphans = events.filter { $0.listID == nil }
        guard !orphans.isEmpty else { return }

        // Create a default list if none exists yet
        if todoLists.isEmpty {
            let defaultList = TodoList(title: "Default", colorName: "blue")
            todoLists.append(defaultList)
            saveTodoLists()
        }

        let targetListID = todoLists[0].id
        for i in events.indices where events[i].listID == nil {
            events[i].listID = targetListID
        }
        save()
    }

    func save() {
        do {
            let data = try JSONEncoder().encode(events)
            defaults.set(data, forKey: storageKey)
        } catch {
            defaults.removeObject(forKey: storageKey)
        }
    }

    private func saveCalendarEvents() {
        do {
            let data = try JSONEncoder().encode(calendarEvents)
            defaults.set(data, forKey: calendarStorageKey)
        } catch {
            defaults.removeObject(forKey: calendarStorageKey)
        }
        syncWidgetSnapshots()
    }

    private func syncWidgetSnapshots() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        // Cover a 7-day window so the widget has upcoming data
        let windowStart = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let windowEnd = calendar.date(byAdding: .day, value: 7, to: today) ?? today

        var snapshots: [SharedEventSnapshot] = []

        for event in calendarEvents {
            if event.isRecurringSeries {
                // Expand recurring events into daily occurrences within the window
                var day = windowStart
                while day < windowEnd {
                    if let range = CalendarLayout.recurrenceOccurrence(for: event, on: day, calendar: calendar) {
                        snapshots.append(SharedEventSnapshot(
                            id: event.id,
                            title: event.title,
                            type: event.type,
                            colorHex: EventTypeTemplateStore.colorHex(for: event.type),
                            startDate: range.start,
                            endDate: range.end,
                            isAllDay: event.isAllDay,
                            isDone: event.isDone,
                            isInterrupt: event.isInterrupt,
                            parentEventID: event.interruptRelation?.parentEventID
                        ))
                    }
                    day = calendar.date(byAdding: .day, value: 1, to: day) ?? windowEnd
                }
            } else {
                for range in event.timeRanges {
                    // Only include events within the window
                    if range.end >= windowStart && range.start <= windowEnd {
                        snapshots.append(SharedEventSnapshot(
                            id: event.id,
                            title: event.title,
                            type: event.type,
                            colorHex: EventTypeTemplateStore.colorHex(for: event.type),
                            startDate: range.start,
                            endDate: range.end,
                            isAllDay: event.isAllDay,
                            isDone: event.isDone,
                            isInterrupt: event.isInterrupt,
                            parentEventID: event.interruptRelation?.parentEventID
                        ))
                    }
                }
            }
        }

        SharedWidgetData.write(
            events: snapshots,
            timeFormat: AppTimeFormat.current.rawValue,
            language: AppLanguage.current.rawValue
        )
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func saveCalendarEventFeedbackRecords() {
        do {
            let data = try JSONEncoder().encode(calendarEventFeedbackRecords)
            defaults.set(data, forKey: calendarEventFeedbackStorageKey)
        } catch {
            defaults.removeObject(forKey: calendarEventFeedbackStorageKey)
        }
    }

    private func saveCalendarEventLogRecords() {
        do {
            let data = try JSONEncoder().encode(calendarEventLogRecords)
            defaults.set(data, forKey: calendarEventLogStorageKey)
        } catch {
            defaults.removeObject(forKey: calendarEventLogStorageKey)
        }
    }

    func clearAllLocalData() {
        events = []
        calendarEvents = []
        calendarEventFeedbackRecords = []
        calendarEventLogRecords = []
        todoLists = []

        defaults.removeObject(forKey: storageKey)
        defaults.removeObject(forKey: calendarStorageKey)
        defaults.removeObject(forKey: calendarEventFeedbackStorageKey)
        defaults.removeObject(forKey: calendarEventLogStorageKey)
        defaults.removeObject(forKey: todoListsStorageKey)
    }

    @discardableResult
    private func refreshInterruptRelationStates(in events: inout [Event]) -> Bool {
        var changed = false
        for index in events.indices {
            guard var relation = events[index].interruptRelation else { continue }
            let resolvedState = resolveInterruptRelationState(
                for: events[index],
                relation: relation,
                in: events
            )
            if relation.state != resolvedState {
                relation.state = resolvedState
                events[index].interruptRelation = relation
                changed = true
            }
        }
        return changed
    }

    private func resolveInterruptRelationState(
        for event: Event,
        relation: EventInterruptRelation,
        in events: [Event]
    ) -> EventInterruptRelationState {
        guard let childRange = event.primaryTimeRange else {
            return relation.state
        }
        guard let parentRange = resolveInterruptParentRange(for: relation, in: events) else {
            return .orphaned
        }
        return parentRange.end > childRange.start && parentRange.start < childRange.end
            ? .embedded
            : .detached
    }

    private func resolveInterruptParentRange(
        for relation: EventInterruptRelation,
        in events: [Event]
    ) -> Event.TimeRange? {
        let calendar = Calendar.current
        let targetDay = calendar.startOfDay(for: relation.occurrenceDate)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: targetDay) ?? targetDay
        let anchorEventID = relation.parentEventID
        let baseSeriesEventID = relation.baseSeriesEventID ?? relation.parentEventID

        if let exact = events.first(where: { $0.id == anchorEventID }) {
            if exact.isRecurringSeries {
                if let range = CalendarLayout.recurrenceOccurrence(for: exact, on: targetDay, calendar: calendar) {
                    return range
                }
            } else if let range = exact.primaryTimeRange,
                      range.end > targetDay,
                      range.start < dayEnd {
                return range
            }
        }

        if let exception = events.first(where: { candidate in
            candidate.recurrenceParentId == baseSeriesEventID
                && candidate.recurrenceInstanceDate.map { calendar.isDate($0, inSameDayAs: targetDay) } == true
        }) {
            return exception.primaryTimeRange
        }

        return nil
    }

    private func saveCalendarEvents(refreshInterrupts: Bool) {
        if refreshInterrupts {
            _ = refreshInterruptRelationStates(in: &calendarEvents)
        }
        saveCalendarEvents()
    }

    // MARK: - Lookup Helpers

    func findEvent(id: UUID) -> Event? {
        events.first(where: { $0.id == id })
    }

    @discardableResult
    func mutateEvent(id: UUID, _ transform: (inout Event) -> Void) -> Bool {
        guard let index = events.firstIndex(where: { $0.id == id }) else { return false }
        transform(&events[index])
        return true
    }

    func findCalendarEvent(id: UUID) -> Event? {
        calendarEvents.first(where: { $0.id == id })
    }

    @discardableResult
    func mutateCalendarEvent(id: UUID, _ transform: (inout Event) -> Void) -> Bool {
        guard let index = calendarEvents.firstIndex(where: { $0.id == id }) else { return false }
        transform(&calendarEvents[index])
        return true
    }

    // MARK: - TodoList CRUD

    private func saveTodoLists() {
        do {
            let data = try JSONEncoder().encode(todoLists)
            defaults.set(data, forKey: todoListsStorageKey)
        } catch {
            defaults.removeObject(forKey: todoListsStorageKey)
        }
    }

    func addList(_ list: TodoList) {
        todoLists.append(list)
        saveTodoLists()
    }

    func updateList(_ list: TodoList) {
        if let index = todoLists.firstIndex(where: { $0.id == list.id }) {
            todoLists[index] = list
            saveTodoLists()
        }
    }

    func deleteList(_ list: TodoList) {
        todoLists.removeAll { $0.id == list.id }
        saveTodoLists()
    }

    func events(for list: TodoList) -> [Event] {
        events.filter { $0.listID == list.id && $0.status == .active }
    }

    func eventCount(for list: TodoList) -> Int {
        events.filter { $0.listID == list.id && $0.status == .active }.count
    }

    // MARK: - Calendar CRUD

    func addCalendarEvent(_ event: Event) {
        calendarEvents.append(event)
        saveCalendarEvents(refreshInterrupts: true)
        onCalendarEventRecordCompleted?(event)
        calendarEventRecorded.send(event)
    }

    func updateCalendarEvent(_ event: Event) {
        guard mutateCalendarEvent(id: event.id, { $0 = event }) else {
            assertionFailure("EventStore.updateCalendarEvent missing id: \(event.id.uuidString)")
            NSLog("EventStore.updateCalendarEvent missing id: %@", event.id.uuidString)
            return
        }
        saveCalendarEvents(refreshInterrupts: true)
        onCalendarEventRecordCompleted?(event)
        calendarEventRecorded.send(event)
    }

    func deleteCalendarEvent(_ event: Event) {
        if let intake = findCalendarEvent(id: event.id)?.agenticIntake {
            AgenticIntakeAssetStore().removeAssets(for: intake)
        }
        orphanInterruptChildren(forParentDeletion: event)
        if event.isInterrupt {
            pruneInterruptTimelineItems(for: event.id)
        }
        pruneFeedbackForDeletedCalendarEvent(event)
        pruneLogRecordsForDeletedCalendarEvent(event)
        calendarEvents.removeAll { $0.id == event.id }
        saveCalendarEvents(refreshInterrupts: true)
    }

    // MARK: - Recurrence

    func findSeriesEvent(for event: Event) -> Event? {
        if event.isRecurringSeries { return event }
        guard let parentId = event.recurrenceParentId else { return nil }
        return calendarEvents.first { $0.id == parentId }
    }

    func applyRecurringEdit(
        seriesEvent: Event,
        occurrenceDate: Date,
        scope: Event.RecurrenceEditScope,
        edit: (inout Event) -> Void
    ) {
        let result = Event.applyEdit(
            series: seriesEvent,
            occurrenceDate: occurrenceDate,
            scope: scope,
            edit: edit
        )
        if let updated = result.updatedSeries {
            updateCalendarEvent(updated)
        }
        if let newSeries = result.newSeries {
            addCalendarEvent(newSeries)
        }
        if let exception = result.exceptionInstance {
            addCalendarEvent(exception)
        }
    }

    func deleteRecurringCalendarEvent(
        seriesEvent: Event,
        occurrenceDate: Date,
        scope: Event.RecurrenceEditScope
    ) {
        let calendar = Calendar.current
        let occurrenceDay = calendar.startOfDay(for: occurrenceDate)
        pruneFeedbackForDeletedRecurringSeries(
            seriesEvent: seriesEvent,
            occurrenceDate: occurrenceDay,
            scope: scope
        )
        pruneLogRecordsForDeletedRecurringSeries(
            seriesEvent: seriesEvent,
            occurrenceDate: occurrenceDay,
            scope: scope
        )
        orphanInterruptChildren(
            forDeletedRecurringSeries: seriesEvent,
            occurrenceDate: occurrenceDay,
            scope: scope
        )

        switch scope {
        case .all:
            calendarEvents.removeAll { $0.id == seriesEvent.id }
            // Also remove any exception instances
            calendarEvents.removeAll { $0.recurrenceParentId == seriesEvent.id }
            saveCalendarEvents(refreshInterrupts: true)

        case .single:
            var updated = seriesEvent
            updated.recurrenceExceptionDates.append(occurrenceDay)
            updateCalendarEvent(updated)

        case .following:
            let endCutoff = calendar.date(byAdding: .day, value: -1, to: occurrenceDay)
            var updated = seriesEvent
            updated.repeatEndType = .onDate
            updated.repeatEndDate = endCutoff
            updateCalendarEvent(updated)
        }
    }

    // MARK: - Calendar Feedback / Logs (Occurrence-scoped)

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

    private func syncCalendarEventColorDepthIfNeeded(eventID: UUID, effort: Int?) {
        guard let index = calendarEvents.firstIndex(where: { $0.id == eventID }) else { return }
        let targetColorDepth = Event.colorDepth(forEffort: effort)
        guard abs(calendarEvents[index].colorDepth - targetColorDepth) > 0.0001 else { return }
        var updatedEvent = calendarEvents[index]
        updatedEvent.colorDepth = targetColorDepth
        calendarEvents[index] = updatedEvent
        saveCalendarEvents(refreshInterrupts: false)
    }

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
    private func pruneRecords<T: OccurrenceRecord>(
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
    private func pruneRecords<T: OccurrenceRecord>(
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

    func add(_ event: Event) {
        events.append(event)
        save()
    }

    func addWithAutoPlacement(_ event: Event) {
        add(event)
    }

    func update(_ event: Event) {
        if mutateEvent(id: event.id, { $0 = event }) {
            save()
        }
    }

    func delete(_ event: Event) {
        // Stop timer if this todo has an active timer
        if let linkedId = event.linkedCalendarEventId,
           findCalendarEvent(id: linkedId)?.timerStartedAt != nil {
            let now = Date()
            mutateCalendarEvent(id: linkedId, { cal in
                cal.timerStartedAt = nil
                cal.timeRanges = [Event.TimeRange(start: cal.primaryTimeRange?.start ?? now, end: now)]
            })
            saveCalendarEvents()
        }
        events.removeAll { $0.id == event.id }
        save()
    }

    var activeEvents: [Event] {
        events.filter { $0.status == .active }
    }

    var completedEvents: [Event] {
        events
            .filter { $0.status == .completed }
            .sorted { ($0.completeAt ?? .distantPast) > ($1.completeAt ?? .distantPast) }
    }

    var completedCount: Int {
        events.filter { $0.status == .completed }.count
    }

    var archivedEvents: [Event] {
        events.filter { $0.status == .archived }
    }

    var archivedCount: Int {
        events.filter { $0.status == .archived }.count
    }

    func markArchived(_ event: Event) {
        if let linkedId = event.linkedCalendarEventId {
            stopTimerOnCalendarEvent(linkedId)
        }
        guard mutateEvent(id: event.id, { $0.status = .archived }) else { return }
        save()
    }

    func restoreFromArchive(_ event: Event) {
        guard mutateEvent(id: event.id, { $0.status = .active }) else { return }
        save()
    }

    func permanentlyDelete(_ event: Event) {
        events.removeAll { $0.id == event.id }
        save()
    }

    func markComplete(_ event: Event) {
        if let linkedId = event.linkedCalendarEventId {
            stopTimerOnCalendarEvent(linkedId)
        }
        guard mutateEvent(id: event.id, {
            $0.status = .completed
            $0.isDone = true
            $0.completeAt = Date()
        }) else { return }
        save()
    }

    func completeWanna(_ event: Event) {
        let now = Date()

        // Mark the wanna as completed
        markComplete(event)

        // Stamp on the active calendar event's timeline (if any)
        if let activeEvent = currentlyActiveCalendarEvent(at: now) {
            let occurrence = CalendarEventOccurrenceContext(
                eventID: activeEvent.id,
                occurrenceDate: activeEvent.primaryTimeRange?.start ?? now,
                occurrenceID: nil,
                isAllDay: activeEvent.isAllDay,
                source: .timelineTap
            )
            upsertLogRecord(for: occurrence) { record in
                record.timelineItems.append(
                    .wannaCompletion(
                        EventLogWannaCompletion(
                            wannaEventID: event.id,
                            title: event.title,
                            createdAt: now
                        )
                    )
                )
            }
        }
    }

    func currentlyActiveCalendarEvent(at date: Date = Date()) -> Event? {
        // First check timer-based active event
        if let timerEvent = activeTimerCalendarEvent {
            return timerEvent
        }
        // Then check if any event's time range contains the current time
        return calendarEvents.first { event in
            event.timeRanges.contains { range in
                range.start <= date && date <= range.end
            }
        }
    }

    func markActive(_ event: Event) {
        guard mutateEvent(id: event.id, {
            $0.status = .active
            $0.isDone = false
            $0.completeAt = nil
        }) else { return }
        save()
    }

    @discardableResult
    func smartSplitEvent(_ event: Event, subtasks: [(title: String, portion: Double)]) -> SmartSplitUndoInfo? {
        guard subtasks.count >= 2 else { return nil }

        let originalCopy = event
        delete(event)

        var newIDs: [UUID] = []
        for st in subtasks {
            let childID = UUID()
            let child = Event(
                id: childID,
                title: st.title,
                note: event.note,
                deadline: event.deadline,
                priority: event.priority,
                tags: event.tags,
                type: event.type,
                colorDepth: event.colorDepth,
                listID: event.listID
            )
            add(child)
            newIDs.append(childID)
        }

        return SmartSplitUndoInfo(originalEvent: originalCopy, newEventIDs: newIDs)
    }

    func undoSmartSplit(_ info: SmartSplitUndoInfo) {
        for id in info.newEventIDs {
            if let child = findEvent(id: id) {
                delete(child)
            }
        }
        add(info.originalEvent)
    }

    @discardableResult
    func mergeEvents(source: Event, into target: Event) -> MergeUndoInfo {
        var merged = target

        // title: "A / B"
        merged.title = "\(target.title) / \(source.title)"

        // tags: union (deduplicated, preserving order)
        merged.tags = (target.tags + source.tags).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }

        // timeRanges: combine and sort by start
        let allRanges = target.effectiveTimeRanges + source.effectiveTimeRanges
        merged.timeRanges = allRanges.sorted { $0.start < $1.start }

        // note: concatenate non-empty with newline
        if !target.note.isEmpty && !source.note.isEmpty {
            merged.note = "\(target.note)\n\(source.note)"
        } else if !source.note.isEmpty {
            merged.note = source.note
        }

        // priority: take the larger value
        merged.priority = max(target.priority, source.priority)

        // deadline: take the later one
        switch (target.deadline, source.deadline) {
        case let (a?, b?):
            merged.deadline = max(a, b)
        case let (nil, b?):
            merged.deadline = b
        default:
            break
        }

        update(merged)
        delete(source)

        return MergeUndoInfo(sourceEvent: source, targetEvent: target, mergedEventID: merged.id)
    }

    func undoMerge(_ info: MergeUndoInfo) {
        // Restore original target event
        update(info.targetEvent)
        // Re-add original source event
        add(info.sourceEvent)
    }

    // MARK: - Timer

    var activeTimerCalendarEvent: Event? {
        calendarEvents.first { $0.timerStartedAt != nil }
    }

    func isTimerRunning(for todoEvent: Event) -> Bool {
        guard let linkedId = todoEvent.linkedCalendarEventId else { return false }
        return findCalendarEvent(id: linkedId)?.timerStartedAt != nil
    }

    func startTimer(for todoEvent: Event) {
        // Stop any existing active timer first
        stopActiveTimer()

        let now = Date()
        let calendarEventId = UUID()

        // Create calendar event linked to this todo
        let calEvent = Event(
            id: calendarEventId,
            title: todoEvent.title,
            timeRanges: [Event.TimeRange(start: now, end: now)],
            type: todoEvent.type,
            timerStartedAt: now,
            linkedTodoEventId: todoEvent.id
        )
        calendarEvents.append(calEvent)
        saveCalendarEvents()

        // Link todo to calendar event
        if mutateEvent(id: todoEvent.id, { $0.linkedCalendarEventId = calendarEventId }) {
            save()
        }
    }

    func stopTimer(for todoEvent: Event) {
        guard let linkedId = todoEvent.linkedCalendarEventId else { return }
        stopTimerOnCalendarEvent(linkedId)
    }

    func stopActiveTimer() {
        guard let activeEvent = activeTimerCalendarEvent else { return }
        stopTimerOnCalendarEvent(activeEvent.id)
    }

    var onCalendarEventRecordCompleted: ((Event) -> Void)?

    private func stopTimerOnCalendarEvent(_ calendarEventId: UUID) {
        let now = Date()
        guard mutateCalendarEvent(id: calendarEventId, { cal in
            let startTime = cal.timerStartedAt ?? cal.primaryTimeRange?.start ?? now
            cal.timerStartedAt = nil
            cal.timeRanges = [Event.TimeRange(start: startTime, end: now)]
        }) else { return }
        saveCalendarEvents()
        if let updated = findCalendarEvent(id: calendarEventId) {
            onCalendarEventRecordCompleted?(updated)
            calendarEventRecorded.send(updated)
        }
    }

    func reorderEvents(inList listID: UUID?, newOrder: [UUID]) {
        let filteredIndices = events.indices.filter {
            events[$0].listID == listID && events[$0].status == .active
        }
        guard newOrder.count == filteredIndices.count else { return }
        var reordered: [Event] = []
        reordered.reserveCapacity(newOrder.count)
        for id in newOrder {
            guard let event = findEvent(id: id) else { return }
            reordered.append(event)
        }
        for (i, globalIndex) in filteredIndices.enumerated() {
            events[globalIndex] = reordered[i]
        }
        save()
    }

    func replaceAll(_ newEvents: [Event]) {
        events = newEvents
        save()
    }

    @discardableResult
    func createInterrupt(
        parentEvent: Event,
        occurrenceDate: Date,
        title: String,
        timeRange: Event.TimeRange
    ) -> Event? {
        createInterrupt(
            parentEvent: parentEvent,
            occurrenceDate: occurrenceDate,
            title: title,
            type: nil,
            timeRange: timeRange
        )
    }

    @discardableResult
    func createInterrupt(
        parentEvent: Event,
        occurrenceDate: Date,
        title: String,
        type: String? = nil,
        timeRange: Event.TimeRange
    ) -> Event? {
        guard timeRange.end > timeRange.start else { return nil }
        let occurrenceKey = CalendarOccurrenceKey.make(
            for: parentEvent,
            occurrenceDate: occurrenceDate
        )
        let relation = EventInterruptRelation(
            parentEventID: occurrenceKey.eventID,
            baseSeriesEventID: occurrenceKey.baseSeriesEventID,
            occurrenceDate: occurrenceKey.occurrenceDate,
            state: .embedded,
            createdAt: timeRange.start
        )
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedType = type?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let interruptEvent = Event(
            title: trimmedTitle.isEmpty ? "Interrupt" : trimmedTitle,
            note: "",
            location: "",
            timeRanges: [timeRange],
            type: trimmedType.isEmpty ? parentEvent.type : trimmedType,
            displayKind: .interrupt,
            interruptRelation: relation
        )
        addCalendarEvent(interruptEvent)

        let occurrence = CalendarEventOccurrenceContext(
            eventID: occurrenceKey.eventID,
            occurrenceDate: occurrenceKey.occurrenceDate,
            occurrenceID: nil,
            isAllDay: false,
            source: .timelineLongPress
        )
        upsertLogRecord(for: occurrence) { record in
            record.timelineItems.append(
                .interruptRef(
                    EventLogInterruptReference(
                        childEventID: interruptEvent.id,
                        createdAt: timeRange.start
                    )
                )
            )
            record.timelineItems.sort { $0.createdAt > $1.createdAt }
        }
        return interruptEvent
    }

    @discardableResult
    func attachInterrupt(
        to childEventID: UUID,
        parentEvent: Event,
        occurrenceDate: Date,
        createdAt: Date? = nil,
        seedTypeTitle: String? = nil
    ) -> Bool {
        guard let child = findCalendarEvent(id: childEventID) else { return false }

        let occurrenceKey = CalendarOccurrenceKey.make(
            for: parentEvent,
            occurrenceDate: occurrenceDate
        )
        let timestamp = createdAt ?? child.primaryTimeRange?.start ?? Date()
        let relation = EventInterruptRelation(
            parentEventID: occurrenceKey.eventID,
            baseSeriesEventID: occurrenceKey.baseSeriesEventID,
            occurrenceDate: occurrenceKey.occurrenceDate,
            state: .embedded,
            createdAt: timestamp
        )
        let trimmedSeedType = seedTypeTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard mutateCalendarEvent(id: childEventID, { event in
            event.displayKind = .interrupt
            event.interruptRelation = relation
            if event.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                event.title = "Interrupt"
            }
            if !trimmedSeedType.isEmpty {
                event.type = trimmedSeedType
            }
        }) else {
            return false
        }
        saveCalendarEvents(refreshInterrupts: true)

        let occurrence = CalendarEventOccurrenceContext(
            eventID: occurrenceKey.eventID,
            occurrenceDate: occurrenceKey.occurrenceDate,
            occurrenceID: nil,
            isAllDay: false,
            source: .timelineLongPress
        )
        upsertLogRecord(for: occurrence) { record in
            if !record.timelineItems.contains(where: { $0.interruptReferenceValue?.childEventID == childEventID }) {
                record.timelineItems.append(
                    .interruptRef(
                        EventLogInterruptReference(
                            childEventID: childEventID,
                            createdAt: timestamp
                        )
                    )
                )
            }
            record.timelineItems.sort { $0.createdAt > $1.createdAt }
        }
        return true
    }

    func refreshInterruptRelationState(for eventID: UUID) {
        guard let index = calendarEvents.firstIndex(where: { $0.id == eventID }),
              let relation = calendarEvents[index].interruptRelation else {
            return
        }
        let resolvedState = resolveInterruptRelationState(
            for: calendarEvents[index],
            relation: relation,
            in: calendarEvents
        )
        guard relation.state != resolvedState else { return }
        calendarEvents[index].interruptRelation?.state = resolvedState
        saveCalendarEvents()
    }

    func pruneInterruptTimelineItems(for childEventID: UUID) {
        var didChange = false
        for index in calendarEventLogRecords.indices {
            let originalCount = calendarEventLogRecords[index].timelineItems.count
            calendarEventLogRecords[index].timelineItems.removeAll { item in
                item.interruptReferenceValue?.childEventID == childEventID
            }
            if calendarEventLogRecords[index].timelineItems.count != originalCount {
                calendarEventLogRecords[index].updatedAt = Date()
                didChange = true
            }
        }
        if didChange {
            saveCalendarEventLogRecords()
        }
    }

    func orphanInterruptChildren(forParentDeletion event: Event) {
        let calendar = Calendar.current
        let anchorEventID = event.isExceptionInstance
            ? (event.recurrenceParentId ?? event.id)
            : event.id
        let targetDay = calendar.startOfDay(
            for: event.recurrenceInstanceDate
                ?? event.primaryTimeRange?.start
                ?? Date.distantPast
        )

        var changed = false
        for index in calendarEvents.indices {
            guard var relation = calendarEvents[index].interruptRelation else { continue }
            let matchesAnchor = relation.parentEventID == anchorEventID
            let matchesDay = !event.isExceptionInstance
                || calendar.isDate(relation.occurrenceDate, inSameDayAs: targetDay)
            guard matchesAnchor && matchesDay else { continue }
            if relation.state != .orphaned {
                relation.state = .orphaned
                calendarEvents[index].interruptRelation = relation
                changed = true
            }
        }
        if changed {
            saveCalendarEvents()
        }
    }

    func orphanInterruptChildren(
        forDeletedRecurringSeries seriesEvent: Event,
        occurrenceDate: Date,
        scope: Event.RecurrenceEditScope
    ) {
        let calendar = Calendar.current
        let targetDay = calendar.startOfDay(for: occurrenceDate)
        var changed = false

        for index in calendarEvents.indices {
            guard var relation = calendarEvents[index].interruptRelation else { continue }
            guard relation.parentEventID == seriesEvent.id else { continue }

            let shouldOrphan: Bool
            switch scope {
            case .all:
                shouldOrphan = true
            case .single:
                shouldOrphan = calendar.isDate(relation.occurrenceDate, inSameDayAs: targetDay)
            case .following:
                shouldOrphan = relation.occurrenceDate >= targetDay
            }

            guard shouldOrphan else { continue }
            if relation.state != .orphaned {
                relation.state = .orphaned
                calendarEvents[index].interruptRelation = relation
                changed = true
            }
        }

        if changed {
            saveCalendarEvents()
        }
    }

    private func calendarOccurrenceKey(for occurrence: CalendarEventOccurrenceContext) -> CalendarOccurrenceKey? {
        guard let event = findCalendarEvent(id: occurrence.eventID) else {
            return nil
        }
        return CalendarOccurrenceKey.make(for: event, occurrenceDate: occurrence.occurrenceDate)
    }

}
