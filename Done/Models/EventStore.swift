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

enum TodoCalendarTransferDirection {
    case todoToCalendar
    case calendarToTodo
}

struct TodoCalendarTransferUndoToken {
    let direction: TodoCalendarTransferDirection
    let sourceEvent: Event
    let sourceIndex: Int
    let destinationEvent: Event
    let destinationIndex: Int
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
        guard let index = calendarEvents.firstIndex(where: { $0.id == event.id }) else {
            assertionFailure("EventStore.updateCalendarEvent missing id: \(event.id.uuidString)")
            NSLog("EventStore.updateCalendarEvent missing id: %@", event.id.uuidString)
            return
        }
        calendarEvents[index] = event
        saveCalendarEvents()
        onCalendarEventRecordCompleted?(event)
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

    func reorderEvents(inList listID: UUID?, newOrder: [UUID]) {
        let filteredIndices = events.indices.filter {
            events[$0].listID == listID && events[$0].status == .active
        }
        let reordered = newOrder.compactMap { id in events.first { $0.id == id } }
        guard reordered.count == filteredIndices.count else { return }
        for (i, globalIndex) in filteredIndices.enumerated() {
            events[globalIndex] = reordered[i]
        }
        save()
    }

    func replaceAll(_ newEvents: [Event]) {
        events = newEvents
        save()
    }

    // MARK: - Planned Todo (Calendar Reveal Experiment)

    func plannedTodoEvents(on plannedDate: Date, listID: UUID? = nil) -> [Event] {
        let day = normalizePlannedDay(plannedDate)
        return events
            .filter { event in
                event.status == .active
                    && normalizePlannedDay(event.todoPlannedDate) == day
                    && (listID == nil || event.listID == listID)
            }
            .sorted { plannedTodoSort(lhs: $0, rhs: $1) }
    }

    @discardableResult
    func createPlannedTodo(
        listID: UUID?,
        title: String,
        plannedDate: Date,
        durationMinutes: Int
    ) -> Event {
        let normalizedDay = normalizePlannedDay(plannedDate)
        let resolvedListID = listID ?? defaultTodoListID()
        let resolvedDurationMinutes = max(15, durationMinutes)
        let order = nextTopTodoStackOrder(on: normalizedDay, listID: resolvedListID)

        let event = Event(
            title: title,
            startTime: nil,
            endTime: nil,
            timeRanges: [],
            status: .active,
            todoPlannedDate: normalizedDay,
            todoPlannedDurationMinutes: resolvedDurationMinutes,
            todoStackOrder: order,
            listID: resolvedListID
        )
        events.append(event)
        save()
        return event
    }

    func reorderPlannedTodo(
        on plannedDate: Date,
        listID: UUID?,
        orderedIDs: [UUID]
    ) {
        let normalizedDay = normalizePlannedDay(plannedDate)
        let targetIndices = events.indices.filter { index in
            let event = events[index]
            return event.status == .active
                && normalizePlannedDay(event.todoPlannedDate) == normalizedDay
                && (listID == nil || event.listID == listID)
        }
        guard !targetIndices.isEmpty else { return }

        let idToIndex: [UUID: Int] = Dictionary(
            uniqueKeysWithValues: targetIndices.map { (events[$0].id, $0) }
        )
        var ordered = orderedIDs
        let existingIDs = Set(idToIndex.keys)
        ordered.removeAll { !existingIDs.contains($0) }
        let missing = existingIDs.filter { !Set(ordered).contains($0) }
        ordered.append(contentsOf: missing)

        for (order, id) in ordered.enumerated() {
            guard let index = idToIndex[id] else { continue }
            events[index].todoStackOrder = order
            events[index].todoPlannedDate = normalizedDay
        }
        save()
    }

    func moveTodoEventToCalendar(
        eventID: UUID,
        droppedStart: Date
    ) -> TodoCalendarTransferUndoToken? {
        guard let sourceIndex = events.firstIndex(where: { $0.id == eventID }) else { return nil }
        let sourceEvent = events[sourceIndex]
        guard !sourceEvent.isAllDay,
              !sourceEvent.isRecurringSeries,
              !sourceEvent.isExceptionInstance else { return nil }

        let start = droppedStart
        let durationMinutes = resolvedTodoDurationMinutes(for: sourceEvent)
        let end = start.addingTimeInterval(TimeInterval(durationMinutes * 60))

        var destinationEvent = sourceEvent
        destinationEvent.startTime = start
        destinationEvent.endTime = end
        destinationEvent.timeRanges = [Event.TimeRange(start: start, end: end)]
        destinationEvent.timerStartedAt = nil
        destinationEvent.todoPlannedDate = nil
        destinationEvent.todoPlannedDurationMinutes = nil
        destinationEvent.todoStackOrder = nil

        events.remove(at: sourceIndex)
        calendarEvents.append(destinationEvent)
        let destinationIndex = calendarEvents.count - 1
        save()
        saveCalendarEvents()

        return TodoCalendarTransferUndoToken(
            direction: .todoToCalendar,
            sourceEvent: sourceEvent,
            sourceIndex: sourceIndex,
            destinationEvent: destinationEvent,
            destinationIndex: destinationIndex
        )
    }

    func moveCalendarEventToTodo(
        eventID: UUID,
        targetDate: Date,
        targetOrder: Int? = nil
    ) -> TodoCalendarTransferUndoToken? {
        guard let sourceIndex = calendarEvents.firstIndex(where: { $0.id == eventID }) else { return nil }
        let sourceEvent = calendarEvents[sourceIndex]
        guard !sourceEvent.isAllDay,
              !sourceEvent.isRecurringSeries,
              !sourceEvent.isExceptionInstance else { return nil }

        let normalizedDay = normalizePlannedDay(targetDate)
        let resolvedListID = sourceEvent.listID ?? defaultTodoListID()
        let durationMinutes = resolvedCalendarDurationMinutes(for: sourceEvent)
        let resolvedOrder = targetOrder ?? nextTopTodoStackOrder(on: normalizedDay, listID: resolvedListID)

        var destinationEvent = sourceEvent
        destinationEvent.startTime = nil
        destinationEvent.endTime = nil
        destinationEvent.timeRanges = []
        destinationEvent.timerStartedAt = nil
        destinationEvent.todoPlannedDate = normalizedDay
        destinationEvent.todoPlannedDurationMinutes = durationMinutes
        destinationEvent.todoStackOrder = resolvedOrder
        destinationEvent.listID = resolvedListID

        calendarEvents.remove(at: sourceIndex)
        events.append(destinationEvent)
        let destinationIndex = events.count - 1
        saveCalendarEvents()
        save()

        return TodoCalendarTransferUndoToken(
            direction: .calendarToTodo,
            sourceEvent: sourceEvent,
            sourceIndex: sourceIndex,
            destinationEvent: destinationEvent,
            destinationIndex: destinationIndex
        )
    }

    func undoTodoCalendarTransfer(_ token: TodoCalendarTransferUndoToken) {
        switch token.direction {
        case .todoToCalendar:
            calendarEvents.removeAll { $0.id == token.destinationEvent.id }
            let restoreIndex = max(0, min(token.sourceIndex, events.count))
            events.insert(token.sourceEvent, at: restoreIndex)
            saveCalendarEvents()
            save()
        case .calendarToTodo:
            events.removeAll { $0.id == token.destinationEvent.id }
            let restoreIndex = max(0, min(token.sourceIndex, calendarEvents.count))
            calendarEvents.insert(token.sourceEvent, at: restoreIndex)
            save()
            saveCalendarEvents()
        }
    }

    private func plannedTodoSort(lhs: Event, rhs: Event) -> Bool {
        let lhsOrder = lhs.todoStackOrder ?? Int.max
        let rhsOrder = rhs.todoStackOrder ?? Int.max
        if lhsOrder != rhsOrder {
            return lhsOrder < rhsOrder
        }
        return lhs.createdAt > rhs.createdAt
    }

    private func normalizePlannedDay(_ date: Date?, calendar: Calendar = .current) -> Date? {
        guard let date else { return nil }
        return calendar.startOfDay(for: date)
    }

    private func normalizePlannedDay(_ date: Date, calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: date)
    }

    private func defaultTodoListID() -> UUID? {
        if let first = todoLists.first {
            return first.id
        }
        return nil
    }

    private func nextTopTodoStackOrder(on plannedDate: Date, listID: UUID?) -> Int {
        let activeOrders = events.compactMap { event -> Int? in
            guard event.status == .active else { return nil }
            guard normalizePlannedDay(event.todoPlannedDate) == plannedDate else { return nil }
            guard listID == nil || event.listID == listID else { return nil }
            return event.todoStackOrder
        }
        if let currentMin = activeOrders.min() {
            return currentMin - 1
        }
        return 0
    }

    private func resolvedTodoDurationMinutes(for event: Event) -> Int {
        if let minutes = event.todoPlannedDurationMinutes, minutes > 0 {
            return max(15, minutes)
        }
        let fallbackFromRange = Int((event.duration / 60).rounded())
        if fallbackFromRange > 0 {
            return max(15, fallbackFromRange)
        }
        return 60
    }

    private func resolvedCalendarDurationMinutes(for event: Event) -> Int {
        let durationSeconds: TimeInterval
        if let range = event.primaryTimeRange {
            durationSeconds = range.end.timeIntervalSince(range.start)
        } else {
            durationSeconds = event.duration
        }
        let minutes = Int((durationSeconds / 60).rounded())
        return max(15, minutes)
    }

}
