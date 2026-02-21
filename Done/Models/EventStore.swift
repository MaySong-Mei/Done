//
//  EventStore.swift
//  Done
//
//  Created by Shiqi Liu on 1/12/26.
//

import Foundation
import Combine

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
    @Published private(set) var todoLists: [TodoList] = []

    private let storageKey = "events"
    private let calendarStorageKey = "calendarEvents"
    private let todoListsStorageKey = "todoLists"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    func load() {
        guard let data = defaults.data(forKey: storageKey) else {
            events = []
            return
        }
        do {
            let decoded = try JSONDecoder().decode([Event].self, from: data)
            events = decoded
        } catch {
            events = []
        }

        if let calData = defaults.data(forKey: calendarStorageKey) {
            do {
                calendarEvents = try JSONDecoder().decode([Event].self, from: calData)
            } catch {
                calendarEvents = []
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
        saveCalendarEvents()
        onCalendarEventRecordCompleted?(event)
    }

    func updateCalendarEvent(_ event: Event) {
        if let index = calendarEvents.firstIndex(where: { $0.id == event.id }) {
            calendarEvents[index] = event
            saveCalendarEvents()
            onCalendarEventRecordCompleted?(event)
        }
    }

    func deleteCalendarEvent(_ event: Event) {
        calendarEvents.removeAll { $0.id == event.id }
        saveCalendarEvents()
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

        switch scope {
        case .all:
            calendarEvents.removeAll { $0.id == seriesEvent.id }
            // Also remove any exception instances
            calendarEvents.removeAll { $0.recurrenceParentId == seriesEvent.id }
            saveCalendarEvents()

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

    func add(_ event: Event) {
        events.append(event)
        save()
    }

    func addWithAutoPlacement(_ event: Event) {
        add(event)
    }

    func update(_ event: Event) {
        if let index = events.firstIndex(where: { $0.id == event.id }) {
            events[index] = event
            save()
        }
    }

    func delete(_ event: Event) {
        // Stop timer if this todo has an active timer
        if let linkedId = event.linkedCalendarEventId,
           let calIndex = calendarEvents.firstIndex(where: { $0.id == linkedId }),
           calendarEvents[calIndex].timerStartedAt != nil {
            calendarEvents[calIndex].timerStartedAt = nil
            calendarEvents[calIndex].endTime = Date()
            calendarEvents[calIndex].timeRanges = [Event.TimeRange(start: calendarEvents[calIndex].startTime ?? Date(), end: Date())]
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

    func markComplete(_ event: Event) {
        guard let index = events.firstIndex(where: { $0.id == event.id }) else { return }
        // Stop timer if active
        if let linkedId = event.linkedCalendarEventId {
            stopTimerOnCalendarEvent(linkedId)
        }
        events[index].status = .completed
        events[index].isDone = true
        events[index].completeAt = Date()
        save()
    }

    func markActive(_ event: Event) {
        guard let index = events.firstIndex(where: { $0.id == event.id }) else { return }
        events[index].status = .active
        events[index].isDone = false
        events[index].completeAt = nil
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
            if let child = events.first(where: { $0.id == id }) {
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

        // tags: union (deduplicated)
        let tagSet = NSOrderedSet(array: target.tags + source.tags)
        merged.tags = tagSet.array as? [String] ?? Array(Set(target.tags + source.tags))

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
        return calendarEvents.first(where: { $0.id == linkedId })?.timerStartedAt != nil
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
            startTime: now,
            endTime: now,
            timeRanges: [Event.TimeRange(start: now, end: now)],
            type: todoEvent.type,
            timerStartedAt: now,
            linkedTodoEventId: todoEvent.id
        )
        calendarEvents.append(calEvent)
        saveCalendarEvents()

        // Link todo to calendar event
        if let index = events.firstIndex(where: { $0.id == todoEvent.id }) {
            events[index].linkedCalendarEventId = calendarEventId
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
        guard let calIndex = calendarEvents.firstIndex(where: { $0.id == calendarEventId }) else { return }
        let now = Date()
        let startTime = calendarEvents[calIndex].timerStartedAt ?? calendarEvents[calIndex].startTime ?? now
        calendarEvents[calIndex].timerStartedAt = nil
        calendarEvents[calIndex].endTime = now
        calendarEvents[calIndex].timeRanges = [Event.TimeRange(start: startTime, end: now)]
        saveCalendarEvents()
        onCalendarEventRecordCompleted?(calendarEvents[calIndex])
    }

    func replaceAll(_ newEvents: [Event]) {
        events = newEvents
        save()
    }

}
