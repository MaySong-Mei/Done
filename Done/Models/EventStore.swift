//
//  EventStore.swift
//  Done
//
//  Created by Shiqi Liu on 1/12/26.
//

import Foundation
import Combine

struct SplitUndoInfo {
    let originalEvent: Event
    let newEventID: UUID
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

    private let storageKey = "events"
    private let calendarStorageKey = "calendarEvents"
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
            assignMissingGridPositions()
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
        var event = event
        if event.gridX == nil || event.gridY == nil {
            let position = EventGridLayout.nextAvailablePosition(for: event, in: events)
            event.gridX = position.x
            event.gridY = position.y
        }
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
        events.filter { $0.status == .active && $0.gridX != nil && $0.gridY != nil }
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
        events[index].gridX = nil
        events[index].gridY = nil
        save()
    }

    func markActive(_ event: Event) {
        guard let index = events.firstIndex(where: { $0.id == event.id }) else { return }
        events[index].status = .active
        events[index].isDone = false
        events[index].completeAt = nil
        let position = EventGridLayout.nextAvailablePosition(for: events[index], in: activeEvents)
        events[index].gridX = position.x
        events[index].gridY = position.y
        save()
    }

    @discardableResult
    func splitEvent(_ event: Event) -> SplitUndoInfo? {
        let spanColumns = EventGridLayout.spanColumns(for: event)
        let spanRows = EventGridLayout.spanRows(for: event)
        guard max(spanColumns, spanRows) >= 6 else { return nil }

        let splitByHeight = spanRows > spanColumns

        if splitByHeight {
            guard let originalY = event.gridY else { return nil }
            let topHeight = spanRows / 2
            let bottomHeight = spanRows - topHeight

            var updated = event
            updated.gridHeight = topHeight

            var newEvent = event
            newEvent.id = UUID()
            newEvent.gridY = originalY + topHeight
            newEvent.gridHeight = bottomHeight

            update(updated)
            add(newEvent)

            return SplitUndoInfo(originalEvent: event, newEventID: newEvent.id)
        } else {
            guard let originalX = event.gridX else { return nil }
            let leftWidth = spanColumns / 2
            let rightWidth = spanColumns - leftWidth

            var updated = event
            updated.gridWidth = leftWidth

            var newEvent = event
            newEvent.id = UUID()
            newEvent.gridX = originalX + leftWidth
            newEvent.gridWidth = rightWidth

            update(updated)
            add(newEvent)

            return SplitUndoInfo(originalEvent: event, newEventID: newEvent.id)
        }
    }

    func undoSplit(_ info: SplitUndoInfo) {
        update(info.originalEvent)
        if let newEvent = events.first(where: { $0.id == info.newEventID }) {
            delete(newEvent)
        }
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

        // grid size: grow the larger dimension to fit combined area
        let combinedArea = target.gridWidth * target.gridHeight + source.gridWidth * source.gridHeight
        let targetSpanColumns = EventGridLayout.spanColumns(for: target)
        let targetSpanRows = EventGridLayout.spanRows(for: target)
        if targetSpanRows > targetSpanColumns {
            let newHeight = (combinedArea + target.gridWidth - 1) / target.gridWidth
            merged.gridHeight = max(newHeight, target.gridHeight)
        } else {
            let newWidth = min((combinedArea + target.gridHeight - 1) / target.gridHeight, EventGridLayout.columnsCount)
            merged.gridWidth = max(newWidth, target.gridWidth)
        }

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

    private func assignMissingGridPositions() {
        var occupied: [EventGridLayout.Rect] = []
        var updated = false

        for index in events.indices {
            let event = events[index]
            let spanColumns = EventGridLayout.spanColumns(for: event)
            let spanRows = EventGridLayout.spanRows(for: event)

            if let x = event.gridX, let y = event.gridY {
                occupied.append(
                    EventGridLayout.Rect(x: x, y: y, width: spanColumns, height: spanRows)
                )
                continue
            }

            if !event.effectiveTimeRanges.isEmpty {
                continue
            }

            let position = EventGridLayout.nextAvailablePosition(
                spanColumns: spanColumns,
                spanRows: spanRows,
                occupied: occupied
            )

            events[index].gridX = position.x
            events[index].gridY = position.y
            occupied.append(
                EventGridLayout.Rect(
                    x: position.x,
                    y: position.y,
                    width: spanColumns,
                    height: spanRows
                )
            )
            updated = true
        }

        if updated {
            save()
        }
    }
}
