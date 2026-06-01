//
//  EventStore.swift
//  Done
//
//  Created by Shiqi Liu on 1/12/26.
//

import Foundation
import Combine
import WidgetKit
import os

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Done",
    category: "EventStore"
)

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
    // Setters are internal (not private(set)) so EventStore extensions in
    // other files can mutate the published state. External call sites
    // should still go through the dedicated mutation helpers.
    @Published var events: [Event] = []
    /// Raw underlying calendar-event array — includes absorbed todos
    /// (those with `absorbedIntoEventID != nil`).  Most consumers
    /// should NOT read this directly; use
    /// `canvasRenderableCalendarEvents` for anything that renders on
    /// the canvas, drives analytics, or is user-facing.  Raw is
    /// correct ONLY for ID lookups, sync/restore/mutate paths, and
    /// the handful of deliberate-raw sites documented in
    /// `project_canvas_renderable_audit.md`.  Compile-time enforcement
    /// of this choice is the whole point of having two separate
    /// accessors after audit grouping #4.
    @Published var rawCalendarEvents: [Event] = []
    /// Bumped on every `dominoPushTodosPastHorizon` call (regardless
    /// of whether any todo actually moved).  Views that depend on
    /// `EventZone.horizonDate(...)` re-read it via @EnvironmentObject
    /// observation, so the horizon line and partial-day tint visibly
    /// drift each minute even when no events crossed the threshold.
    /// Treated as opaque — only the change matters, not the value.
    @Published private(set) var dominoTickNonce: Int = 0

    /// Calendar events that should render as independent blocks on the
    /// timeline canvas. Excludes absorbed todos — those with
    /// `absorbedIntoEventID != nil` live as subitems inside their
    /// parent event's detail view, not as their own canvas blocks.
    /// Single source of truth for the canvas-render filter; sync /
    /// detail lookup / mutation paths read `rawCalendarEvents` directly
    /// and still see the full list.
    var canvasRenderableCalendarEvents: [Event] {
        rawCalendarEvents.filter { $0.absorbedIntoEventID == nil }
    }

    /// Absorb a `.todo` into a `.event` parent. Sets
    /// `absorbedIntoEventID`; auto-cascades isDone/status/completeAt
    /// when the parent has already ended (the event happened, so the
    /// intent happened with it). Idempotent — calling on an already-
    /// absorbed todo just overwrites the parent.
    ///
    /// Recurring parents skip the auto-cascade: `timeRanges.last?.end`
    /// on a series is the template's first occurrence, not the most
    /// recent one, so the "is it past?" check is wrong. Manual
    /// markdown still works; correct recurring auto-cascade is parked
    /// alongside the broader recurrence-semantics work.
    ///
    /// Single source of truth for absorption so both the detail-view
    /// picker path and the canvas drag-and-drop path go through the
    /// same write.
    func absorbTodoIntoEvent(todoID: UUID, parentEventID: UUID) {
        // Contract per design Q2: only `.todo` absorbed into `.event`,
        // no nesting. Both ends asserted here so any future entry
        // point (Shortcuts, drag from outside the app, future drag
        // shapes) can't violate the model — silently bail rather than
        // produce a malformed relationship.
        guard let parent = rawCalendarEvents.first(where: { $0.id == parentEventID }),
              parent.kind == .event,
              let source = rawCalendarEvents.first(where: { $0.id == todoID }),
              source.kind == .todo else { return }
        guard mutateCalendarEvent(id: todoID, { todo in
            todo.absorbedIntoEventID = parentEventID
            let now = Date()
            if !parent.isRecurringSeries,
               let parentEnd = parent.timeRanges.last?.end,
               parentEnd < now,
               !todo.isDone {
                todo.isDone = true
                todo.status = .completed
                todo.completeAt = now
            }
        }) else { return }
        saveCalendarEvents(refreshInterrupts: true)
        calendarTodoAbsorbed.send(parentEventID)
    }

    /// Clear `absorbedIntoEventID` on a todo. Doesn't un-mark done —
    /// release ≠ undo; the user can flip done state separately.
    func releaseTodoAbsorption(todoID: UUID) {
        guard mutateCalendarEvent(id: todoID, { $0.absorbedIntoEventID = nil }) else { return }
        saveCalendarEvents(refreshInterrupts: true)
    }

    /// Domino-push every `.todo` whose start sits past `now +
    /// horizonDays × 24h` forward by the elapsed time since the last
    /// push, so they stay at the same relative distance from horizon
    /// (= the canvas "park area" follows the user instead of decaying
    /// past them). First call just stamps the timestamp without
    /// moving anything — there's no last-push to diff against yet.
    ///
    /// Filters:
    ///   - kind == .todo (events are user commitments, never moved)
    ///   - absorbedIntoEventID == nil (absorbed todos live inside a
    ///     parent, are not independent canvas items)
    ///   - !isRecurringSeries (recurring is rule-defined; shifting
    ///     timeRanges is the wrong mutation — recurring todos parked
    ///     until the recurring-events rework lands, issue #5)
    ///
    /// `horizonDays` is passed in (read from AppStorage by the caller
    /// in DoneApp) rather than re-read here, so unit tests can supply
    /// it and the store stays free of settings-key coupling.
    func dominoPushTodosPastHorizon(now: Date = Date(), horizonDays: Int) {
        let lastPushKey = "calendarDominoLastPushTime"
        let rawLast = defaults.double(forKey: lastPushKey)
        guard rawLast > 0 else {
            defaults.set(now.timeIntervalSince1970, forKey: lastPushKey)
            return
        }
        let last = Date(timeIntervalSince1970: rawLast)
        let delta = now.timeIntervalSince(last)
        guard delta > 0 else { return }
        // Filter against the horizon AS OF the last push, NOT the
        // current horizon.  A todo that was past horizon at last push
        // (and therefore got shifted to stay there) might, after a long
        // background gap, sit BEFORE the current horizon — because
        // horizon advanced during the gap while we were silent.  Using
        // the current horizon as the filter would silently abandon
        // that todo (it's now "near-future" by current standards, even
        // though the user parked it as "future" and never touched it).
        // Using horizon-as-of-last-push catches it: it was past then,
        // it deserves the catch-up delta now.  Distance from horizon is
        // preserved: `new_start − new_horizon = old_start − old_horizon`
        // for any delta length, because `EventZone.horizonDate` does
        // pure-seconds arithmetic — `horizonNow − horizonAtLast == delta`
        // exactly, including across DST transitions.
        let horizonAtLast = EventZone.horizonDate(from: horizonDays, now: last)
        var pushedCount = 0
        for i in rawCalendarEvents.indices {
            let event = rawCalendarEvents[i]
            // `firstStart >= horizonAtLast` (not strict `>`): a todo at
            // exactly the boundary should be in the future group too.
            // Multi-range todos: chronological-ascending order assumed
            // (the only multi-range path today is cross-day events
            // which are chronological by construction); the shift
            // mutates ALL ranges uniformly so internal timing stays
            // consistent.
            guard event.kind == .todo,
                  event.absorbedIntoEventID == nil,
                  !event.isRecurringSeries,
                  let firstStart = event.timeRanges.first?.start,
                  firstStart >= horizonAtLast else { continue }
            rawCalendarEvents[i].timeRanges = event.timeRanges.map { range in
                Event.TimeRange(
                    start: range.start.addingTimeInterval(delta),
                    end: range.end.addingTimeInterval(delta)
                )
            }
            pushedCount += 1
        }
        defaults.set(now.timeIntervalSince1970, forKey: lastPushKey)
        if pushedCount > 0 {
            saveCalendarEvents(refreshInterrupts: true)
        }
        dominoTickNonce &+= 1
    }
    @Published var calendarEventFeedbackRecords: [CalendarEventFeedbackRecord] = []
    @Published var calendarEventLogRecords: [CalendarEventLogRecord] = []
    @Published var todoLists: [TodoList] = []
    /// People that can be bound to events (the "with whom" of an event).
    /// App-local; deletion is a soft-archive so historical events still
    /// resolve a name. See `Person`.
    @Published var people: [Person] = []
    /// Named quick-select templates for the people picker. See `FriendGroup`.
    @Published var friendGroups: [FriendGroup] = []

    let calendarEventRecorded = PassthroughSubject<Event, Never>()
    /// Fires the parent's event id every time a todo is absorbed into
    /// it. Subscribers (canvas event-blocks via TimelineDayView)
    /// trigger a transient pulse — useful so the pulse still fires
    /// when the user picker-absorbed while the canvas was covered
    /// (returning to canvas catches the recent-id membership and
    /// animates). Survives view recreations the way `.onChange` on
    /// the count prop doesn't.
    let calendarTodoAbsorbed = PassthroughSubject<UUID, Never>()
    let calendarEventLogChanged = PassthroughSubject<CalendarEventOccurrenceContext, Never>()
    let calendarEventFeedbackChanged = PassthroughSubject<CalendarEventOccurrenceContext, Never>()

    private let storageKey = "events"
    private let calendarStorageKey = "calendarEvents"
    private let calendarEventFeedbackStorageKey = "calendarEventFeedbackRecords"
    private let calendarEventLogStorageKey = "calendarEventLogRecords"
    private let todoListsStorageKey = "todoLists"
    private let peopleStorageKey = "people"
    private let friendGroupsStorageKey = "friendGroups"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    func load() {
        events = decodeOrQuarantine([Event].self, forKey: storageKey)
        rawCalendarEvents = decodeOrQuarantine([Event].self, forKey: calendarStorageKey)
        calendarEventFeedbackRecords = decodeOrQuarantine(
            [CalendarEventFeedbackRecord].self, forKey: calendarEventFeedbackStorageKey
        )
        calendarEventLogRecords = decodeOrQuarantine(
            [CalendarEventLogRecord].self, forKey: calendarEventLogStorageKey
        )
        todoLists = decodeOrQuarantine([TodoList].self, forKey: todoListsStorageKey)
        people = decodeOrQuarantine([Person].self, forKey: peopleStorageKey)
        friendGroups = decodeOrQuarantine([FriendGroup].self, forKey: friendGroupsStorageKey)

        if rawCalendarEvents.isEmpty {
            seedSampleCalendarEvents()
        }
        migrateOrphanEvents()
        syncWidgetSnapshots()
    }

    /// Read & decode a stored UserDefaults JSON blob. On decode failure, copy
    /// the raw bytes to `Documents/quarantine-<key>-<timestamp>.json` (so the
    /// next iCloud Device Backup captures the corrupted data for forensic
    /// recovery) and log loudly, then fall back to empty. The previous
    /// behavior was a silent `[] `which let the next `save()` overwrite the
    /// corrupted blob with empty bytes — effectively destroying it.
    private func decodeOrQuarantine<T: Decodable>(_ type: T.Type, forKey key: String) -> T
    where T: ExpressibleByArrayLiteral {
        guard let data = defaults.data(forKey: key) else { return [] }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            quarantineCorruptedBlob(data, key: key, error: error)
            return []
        }
    }

    /// Persist a copy of the unreadable bytes outside UserDefaults so iCloud
    /// Device Backup can preserve them (Documents/ is always included in
    /// device backup). Filename uses the storage key + timestamp so multiple
    /// quarantines coexist without overwriting each other.
    private func quarantineCorruptedBlob(_ data: Data, key: String, error: Error) {
        let isoTimestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let filename = "quarantine-\(key)-\(isoTimestamp).json"
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            logger.error("Failed to locate Documents directory while quarantining \(key, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }
        let url = docs.appendingPathComponent(filename)
        do {
            try data.write(to: url, options: [.atomic])
            logger.error("Quarantined corrupted UserDefaults blob for \(key, privacy: .public) to \(filename, privacy: .public): \(error.localizedDescription, privacy: .public)")
        } catch let writeError {
            logger.error("Failed to write quarantine file \(filename, privacy: .public) for \(key, privacy: .public): \(writeError.localizedDescription, privacy: .public). Original decode error: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func seedSampleCalendarEvents() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        func time(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(byAdding: .day, value: day, to: today)!
                .addingTimeInterval(TimeInterval(hour * 3600 + minute * 60))
        }

        let samples: [Event] = [
            Event(title: "Morning Focus", note: "Deep work session", location: "", timeRanges: [
                Event.TimeRange(start: time(0, 9), end: time(0, 11, 30))
            ], type: "Work"),
            Event(title: "Team Standup", note: "", location: "Zoom", timeRanges: [
                Event.TimeRange(start: time(0, 11, 30), end: time(0, 12))
            ], type: "Work"),
            Event(title: "Lunch Run", note: "5k around the park", location: "Park", timeRanges: [
                Event.TimeRange(start: time(0, 12, 30), end: time(0, 13, 30))
            ], type: "Exercise"),
            Event(title: "Design Review", note: "Review new feature mockups", location: "", timeRanges: [
                Event.TimeRange(start: time(0, 14), end: time(0, 15, 30))
            ], type: "Work"),
            Event(title: "Reading", note: "Chapters 5-7", location: "", timeRanges: [
                Event.TimeRange(start: time(0, 20), end: time(0, 21, 30))
            ], type: "Study"),
            Event(title: "Piano Practice", note: "", location: "Home", timeRanges: [
                Event.TimeRange(start: time(1, 8), end: time(1, 9))
            ], type: "Hobby"),
            Event(title: "Project Sprint", note: "Feature implementation", location: "", timeRanges: [
                Event.TimeRange(start: time(1, 10), end: time(1, 16))
            ], type: "Work"),
            Event(title: "Grocery Shopping", note: "", location: "Whole Foods", timeRanges: [
                Event.TimeRange(start: time(1, 17), end: time(1, 18))
            ], type: "Errand"),
            Event(title: "Yoga", note: "Vinyasa flow", location: "Studio", timeRanges: [
                Event.TimeRange(start: time(-1, 7), end: time(-1, 8))
            ], type: "Exercise"),
            Event(title: "Coffee Chat", note: "Catch up with Alex", location: "Café", timeRanges: [
                Event.TimeRange(start: time(-1, 10, 30), end: time(-1, 11, 30))
            ], type: "Social"),
        ]

        for event in samples {
            addCalendarEvent(event)
        }
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
            let data = try JSONEncoder().encode(rawCalendarEvents)
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

        for event in rawCalendarEvents {
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

    func saveCalendarEventFeedbackRecords() {
        do {
            let data = try JSONEncoder().encode(calendarEventFeedbackRecords)
            defaults.set(data, forKey: calendarEventFeedbackStorageKey)
        } catch {
            defaults.removeObject(forKey: calendarEventFeedbackStorageKey)
        }
    }

    func saveCalendarEventLogRecords() {
        do {
            let data = try JSONEncoder().encode(calendarEventLogRecords)
            defaults.set(data, forKey: calendarEventLogStorageKey)
        } catch {
            defaults.removeObject(forKey: calendarEventLogStorageKey)
        }
    }

    func clearAllLocalData() {
        events = []
        rawCalendarEvents = []
        calendarEventFeedbackRecords = []
        calendarEventLogRecords = []
        todoLists = []
        people = []
        friendGroups = []

        defaults.removeObject(forKey: storageKey)
        defaults.removeObject(forKey: calendarStorageKey)
        defaults.removeObject(forKey: calendarEventFeedbackStorageKey)
        defaults.removeObject(forKey: calendarEventLogStorageKey)
        defaults.removeObject(forKey: todoListsStorageKey)
        defaults.removeObject(forKey: peopleStorageKey)
        defaults.removeObject(forKey: friendGroupsStorageKey)
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

    func saveCalendarEvents(refreshInterrupts: Bool) {
        if refreshInterrupts {
            _ = refreshInterruptRelationStates(in: &rawCalendarEvents)
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
        rawCalendarEvents.first(where: { $0.id == id })
    }

    @discardableResult
    func mutateCalendarEvent(id: UUID, _ transform: (inout Event) -> Void) -> Bool {
        guard let index = rawCalendarEvents.firstIndex(where: { $0.id == id }) else { return false }
        transform(&rawCalendarEvents[index])
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

    // MARK: - People & Friend Group CRUD

    private func savePeople() {
        do {
            let data = try JSONEncoder().encode(people)
            defaults.set(data, forKey: peopleStorageKey)
        } catch {
            defaults.removeObject(forKey: peopleStorageKey)
        }
    }

    private func saveFriendGroups() {
        do {
            let data = try JSONEncoder().encode(friendGroups)
            defaults.set(data, forKey: friendGroupsStorageKey)
        } catch {
            defaults.removeObject(forKey: friendGroupsStorageKey)
        }
    }

    /// People that should appear in pickers/management lists — excludes
    /// archived (soft-deleted) people.
    var activePeople: [Person] {
        people.filter { !$0.isArchived }
    }

    func person(id: UUID) -> Person? {
        people.first(where: { $0.id == id })
    }

    /// Resolve a list of person ids to `Person` records, preserving order and
    /// silently skipping ids that no longer exist. Used to render an event's
    /// bound people — archived people still resolve so history stays intact.
    func people(for ids: [UUID]) -> [Person] {
        ids.compactMap { id in people.first(where: { $0.id == id }) }
    }

    func addPerson(_ person: Person) {
        people.append(person)
        savePeople()
    }

    /// Create a person by name (deduplicating on a case-insensitive trimmed
    /// match against active people) and return it. Reuses an existing active
    /// person when the name already exists so the picker doesn't spawn
    /// duplicates.
    @discardableResult
    func addPerson(named rawName: String, colorName: String? = nil) -> Person? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        if let existing = activePeople.first(where: {
            $0.name.compare(name, options: .caseInsensitive) == .orderedSame
        }) {
            return existing
        }
        let person = Person(name: name, colorName: colorName)
        addPerson(person)
        return person
    }

    func updatePerson(_ person: Person) {
        if let index = people.firstIndex(where: { $0.id == person.id }) {
            people[index] = person
            savePeople()
        }
    }

    /// Soft-delete: mark the person archived so events that reference them
    /// still resolve a name, but they disappear from selectable lists.
    func archivePerson(_ person: Person) {
        if let index = people.firstIndex(where: { $0.id == person.id }) {
            people[index].isArchived = true
            savePeople()
        }
        // Drop the archived person from group memberships so groups only
        // surface selectable people.
        var didChangeGroups = false
        for index in friendGroups.indices where friendGroups[index].memberIDs.contains(person.id) {
            friendGroups[index].memberIDs.removeAll { $0 == person.id }
            didChangeGroups = true
        }
        if didChangeGroups { saveFriendGroups() }
    }

    func addFriendGroup(_ group: FriendGroup) {
        friendGroups.append(group)
        saveFriendGroups()
    }

    func updateFriendGroup(_ group: FriendGroup) {
        if let index = friendGroups.firstIndex(where: { $0.id == group.id }) {
            friendGroups[index] = group
            saveFriendGroups()
        }
    }

    func deleteFriendGroup(_ group: FriendGroup) {
        friendGroups.removeAll { $0.id == group.id }
        saveFriendGroups()
    }

    func events(for list: TodoList) -> [Event] {
        events.filter { $0.listID == list.id && $0.status == .active }
    }

    // MARK: - Calendar CRUD

    func addCalendarEvent(_ event: Event) {
        rawCalendarEvents.append(event)
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
        // Release any todos absorbed into this event. Without the sweep,
        // children would keep a dead `absorbedIntoEventID` and vanish
        // from canvas (filtered out by canvasRenderable...) while detail
        // still shows the "not absorbed" CTA. Returning them to the
        // canvas restores user agency.
        for index in rawCalendarEvents.indices where rawCalendarEvents[index].absorbedIntoEventID == event.id {
            rawCalendarEvents[index].absorbedIntoEventID = nil
        }
        rawCalendarEvents.removeAll { $0.id == event.id }
        saveCalendarEvents(refreshInterrupts: true)
    }

    // MARK: - Recurrence

    func findSeriesEvent(for event: Event) -> Event? {
        if event.isRecurringSeries { return event }
        guard let parentId = event.recurrenceParentId else { return nil }
        return rawCalendarEvents.first { $0.id == parentId }
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
            rawCalendarEvents.removeAll { $0.id == seriesEvent.id }
            // Also remove any exception instances
            rawCalendarEvents.removeAll { $0.recurrenceParentId == seriesEvent.id }
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
        // Stop timer if this todo has an active timer. Route through the
        // canonical helper so the recorded start instant and the
        // record-completed side effects match stopTimer/markComplete.
        if let linkedId = event.linkedCalendarEventId,
           findCalendarEvent(id: linkedId)?.timerStartedAt != nil {
            stopTimerOnCalendarEvent(linkedId)
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

    // MARK: - Wanna ↔ Calendar

    func pushWannaToCalendar(_ wannaEvent: Event) {
        let now = Date()
        let end = Calendar.current.date(byAdding: .hour, value: 1, to: now) ?? now
        let calendarEventId = UUID()

        let calEvent = Event(
            id: calendarEventId,
            title: wannaEvent.title,
            note: wannaEvent.note,
            timeRanges: [Event.TimeRange(start: now, end: end)],
            type: wannaEvent.type,
            linkedTodoEventId: wannaEvent.id
        )
        rawCalendarEvents.append(calEvent)
        saveCalendarEvents()

        if mutateEvent(id: wannaEvent.id, { $0.linkedCalendarEventId = calendarEventId }) {
            save()
        }
    }

    func recallWannaFromCalendar(_ wannaEvent: Event) {
        guard let linkedId = wannaEvent.linkedCalendarEventId else { return }

        // Stop timer if running
        stopTimerOnCalendarEvent(linkedId)

        // Remove the calendar event
        rawCalendarEvents.removeAll { $0.id == linkedId }
        saveCalendarEvents()

        // Unlink the wanna
        if mutateEvent(id: wannaEvent.id, { $0.linkedCalendarEventId = nil }) {
            save()
        }
    }

    func currentlyActiveCalendarEvent(at date: Date = Date()) -> Event? {
        // First check timer-based active event
        if let timerEvent = activeTimerCalendarEvent {
            return timerEvent
        }
        // Then check if any event's time range contains the current time
        return rawCalendarEvents.first { event in
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
        rawCalendarEvents.first { $0.timerStartedAt != nil }
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
        rawCalendarEvents.append(calEvent)
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
        // Clamp to the parent occurrence's actual range so the child always
        // overlaps with its parent. Live interrupts can outlast the parent
        // if the user holds the live session past parent end; a follow-up
        // edit that nudges the input out of range would also slip past the
        // composer's clamp. Without overlap, the timeline renders the child
        // as a standalone block, visually disconnected from its parent.
        let resolvedTimeRange: Event.TimeRange = {
            guard let parentRange = calendarOccurrenceDisplayRange(
                event: parentEvent,
                occurrenceDate: occurrenceDate
            ) else { return timeRange }
            let start = max(timeRange.start, parentRange.start)
            let end = min(timeRange.end, parentRange.end)
            return Event.TimeRange(start: start, end: end)
        }()
        guard resolvedTimeRange.end > resolvedTimeRange.start else { return nil }
        let occurrenceKey = CalendarOccurrenceKey.make(
            for: parentEvent,
            occurrenceDate: occurrenceDate
        )
        let relation = EventInterruptRelation(
            parentEventID: occurrenceKey.eventID,
            baseSeriesEventID: occurrenceKey.baseSeriesEventID,
            occurrenceDate: occurrenceKey.occurrenceDate,
            state: .embedded,
            createdAt: resolvedTimeRange.start
        )
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedType = type?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let interruptEvent = Event(
            title: trimmedTitle.isEmpty ? "Interrupt" : trimmedTitle,
            note: "",
            location: "",
            timeRanges: [resolvedTimeRange],
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
                        createdAt: resolvedTimeRange.start
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
        guard let index = rawCalendarEvents.firstIndex(where: { $0.id == eventID }),
              let relation = rawCalendarEvents[index].interruptRelation else {
            return
        }
        let resolvedState = resolveInterruptRelationState(
            for: rawCalendarEvents[index],
            relation: relation,
            in: rawCalendarEvents
        )
        guard relation.state != resolvedState else { return }
        rawCalendarEvents[index].interruptRelation?.state = resolvedState
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
        for index in rawCalendarEvents.indices {
            guard var relation = rawCalendarEvents[index].interruptRelation else { continue }
            let matchesAnchor = relation.parentEventID == anchorEventID
            let matchesDay = !event.isExceptionInstance
                || calendar.isDate(relation.occurrenceDate, inSameDayAs: targetDay)
            guard matchesAnchor && matchesDay else { continue }
            if relation.state != .orphaned {
                relation.state = .orphaned
                rawCalendarEvents[index].interruptRelation = relation
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

        for index in rawCalendarEvents.indices {
            guard var relation = rawCalendarEvents[index].interruptRelation else { continue }
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
                rawCalendarEvents[index].interruptRelation = relation
                changed = true
            }
        }

        if changed {
            saveCalendarEvents()
        }
    }

    // MARK: - Restore

    /// Apply a cloud restore snapshot to the local store. Persists each affected
    /// array exactly once after the merge. Callers should not interleave other
    /// mutations on this actor between the in-memory updates and the saves below.
    ///
    /// For `strategy == .merge` the `resolution` decides ID collisions
    /// uniformly across all tables. `perRowDecisions` overrides that on a
    /// per-row basis (per-row review path). For `.cloudOverwritesLocal` both
    /// `resolution` and `perRowDecisions` are ignored — the cloud snapshot
    /// fully replaces local state.
    func applyRestore(
        _ snapshot: RestoreSnapshot,
        strategy: RestoreStrategy,
        resolution: ConflictResolution,
        perRowDecisions: PerRowDecisions? = nil
    ) -> RestoreApplySummary {
        var summary = RestoreApplySummary()

        switch strategy {
        case .cloudOverwritesLocal:
            summary.replacedTotalCount = events.count + rawCalendarEvents.count
                + calendarEventLogRecords.count + calendarEventFeedbackRecords.count
                + todoLists.count
            events = snapshot.todoEvents
            rawCalendarEvents = snapshot.calendarEvents
            calendarEventLogRecords = snapshot.logs
            calendarEventFeedbackRecords = snapshot.feedback
            todoLists = snapshot.todoLists

        case .merge:
            summary.addedTodoEvents = mergeByID(
                local: &events, cloud: snapshot.todoEvents,
                id: \.id, resolution: resolution,
                perRowDecisions: perRowDecisions?.todoEvents
            )
            summary.addedCalendarEvents = mergeByID(
                local: &rawCalendarEvents, cloud: snapshot.calendarEvents,
                id: \.id, resolution: resolution,
                perRowDecisions: perRowDecisions?.calendarEvents
            )
            summary.addedLogs = mergeByID(
                local: &calendarEventLogRecords, cloud: snapshot.logs,
                id: \.id, resolution: resolution,
                perRowDecisions: perRowDecisions?.logs
            )
            summary.addedFeedback = mergeByID(
                local: &calendarEventFeedbackRecords, cloud: snapshot.feedback,
                id: \.id, resolution: resolution,
                perRowDecisions: perRowDecisions?.feedback
            )
            summary.addedLists = mergeByID(
                local: &todoLists, cloud: snapshot.todoLists,
                id: \.id, resolution: resolution,
                perRowDecisions: perRowDecisions?.todoLists
            )
        }

        save()
        saveCalendarEvents()
        saveCalendarEventLogRecords()
        saveCalendarEventFeedbackRecords()
        saveTodoLists()

        return summary
    }

    /// Mutates `local` to be the merged result. Cloud rows whose ID is new are
    /// always appended (returned in `addedCount`). Collisions are resolved
    /// first via `perRowDecisions[id]` if present, then via `resolution`.
    /// `.keepLocal` leaves the local row alone, `.keepCloud` replaces it in
    /// place. Order of existing local rows is preserved.
    private func mergeByID<T, ID: Hashable>(
        local: inout [T],
        cloud: [T],
        id: KeyPath<T, ID>,
        resolution: ConflictResolution,
        perRowDecisions: [ID: ConflictResolution]? = nil
    ) -> Int {
        // `CalendarOccurrenceKey.==` for `.singleEvent` only compares the
        // eventID, so two log/feedback records pointing at the same single
        // event collide on this map. We don't want to crash on
        // `Dictionary(uniqueKeysWithValues:)` for that case — keep the first
        // occurrence's index; subsequent duplicates with the same key inherit
        // its merge decision and are left alone otherwise.
        let localIDIndex: [ID: Int] = Dictionary(
            local.enumerated().map { ($0.element[keyPath: id], $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        var added = 0
        for c in cloud {
            let cid = c[keyPath: id]
            if let idx = localIDIndex[cid] {
                let effective = perRowDecisions?[cid] ?? resolution
                if effective == .keepCloud {
                    local[idx] = c
                }
            } else {
                local.append(c)
                added += 1
            }
        }
        return added
    }
}
