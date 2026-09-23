//
//  AgentToolContainmentTests.swift
//  DoneTests
//
//  gh#135: the agent's destructive tools (deleteTodo, deleteCalendarEvent)
//  once executed hard deletes with zero confirmation. The durable design
//  moves the gate from the OFFERING to EXECUTION:
//
//  - the definitions are offered again — the model may legitimately call a
//    delete tool;
//  - `AgentToolRunner.execute` NEVER mutates for a destructive tool: it
//    resolves the target and stages a typed
//    `AgentPendingDestructiveAction` into the registry the chat UI observes,
//    and tells the model the deletion awaits in-app confirmation;
//  - the actual store mutation lives ONLY in
//    `AgentPendingActionRegistry.confirm`, guarded by nonce and TTL;
//  - the single destructive predicate is
//    `AgentPendingDestructiveAction.Kind(tool:)` (exhaustive switch — a new
//    tool case must declare a side), consumed by the one staging branch in
//    `execute`.
//
//  Both directions carry positive controls: non-destructive tools still
//  execute (and never stage), and the staged card's fields — projected
//  display time (gh#187 family), whole-series warning — are pinned.
//
//  gh#202: the updateTodo deadline argument is three-way — absent leaves the
//  deadline untouched, JSON null removes it, a parseable string sets it —
//  and an unparseable value rejects the WHOLE update atomically (no field
//  applied) instead of silently nil-ing the deadline under success: true.
//  createTodo shares the same contract for its optional deadline.
//

import XCTest
@testable import Done

@MainActor
final class AgentToolContainmentTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var location: EventStorageLocation!
    private var registry: AgentPendingActionRegistry!

    override func setUp() {
        super.setUp()
        suiteName = "AgentToolContainmentTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        location = TestStorage.reset(suiteName)
        registry = AgentPendingActionRegistry()
    }

    override func tearDown() {
        TestStorage.tearDown(suiteName)
        defaults = nil
        suiteName = nil
        location = nil
        registry = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    private func makeStore() -> EventStore {
        EventStore(defaults: defaults, storage: location, seedsSampleDataIfEmpty: false)
    }

    private func seedTodo(into store: EventStore, title: String) -> Event {
        let event = Event(title: title)
        store.addWithAutoPlacement(event)
        return event
    }

    /// A deterministic deadline distinct from anything parseDate would
    /// produce from the argument strings used in these tests.
    private var fixtureDeadline: Date {
        var components = DateComponents()
        components.year = 2031
        components.month = 1
        components.day = 15
        components.hour = 9
        components.minute = 0
        components.second = 0
        return Calendar.current.date(from: components)!
    }

    private func seedTodoWithDeadline(into store: EventStore, title: String) -> Event {
        var event = Event(title: title)
        event.deadline = fixtureDeadline
        store.addWithAutoPlacement(event)
        return event
    }

    private func storedTodo(_ store: EventStore, _ id: UUID,
                            file: StaticString = #filePath, line: UInt = #line) throws -> Event {
        try XCTUnwrap(store.events.first { $0.id == id },
                      "todo missing from store", file: file, line: line)
    }

    private func seedCalendarEvent(into store: EventStore, title: String) -> Event {
        let start = Date()
        let event = Event(
            title: title,
            timeRanges: [Event.TimeRange(start: start, end: start.addingTimeInterval(3600))]
        )
        store.addCalendarEvent(event)
        return event
    }

    private func seedRecurringSeries(into store: EventStore, title: String) -> Event {
        let start = Date()
        let event = Event(
            title: title,
            timeRanges: [Event.TimeRange(start: start, end: start.addingTimeInterval(3600))],
            repeatUnit: .day,
            repeatInterval: 1
        )
        store.addCalendarEvent(event)
        return event
    }

    /// Decodes the runner's jsonResult envelope without `try!`.
    private func decodeResult(
        _ raw: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> (success: Bool, message: String) {
        let object = try decodeJSONObject(raw, file: file, line: line)
        let success = try XCTUnwrap(object["success"] as? Bool, "missing success: \(raw)", file: file, line: line)
        let message = try XCTUnwrap(object["message"] as? String, "missing message: \(raw)", file: file, line: line)
        return (success, message)
    }

    private func decodeJSONObject(
        _ raw: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [String: Any] {
        let data = try XCTUnwrap(raw.data(using: .utf8), "result not UTF-8: \(raw)", file: file, line: line)
        return try XCTUnwrap(
            (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            "result not a JSON object: \(raw)", file: file, line: line
        )
    }

    private func idArguments(_ id: UUID) -> String {
        "{\"id\": \"\(id.uuidString)\"}"
    }

    private func execute(_ toolName: String, arguments: String, store: EventStore) -> String {
        AgentToolRunner.execute(
            toolName: toolName,
            arguments: arguments,
            store: store,
            pendingActions: registry
        )
    }

    // MARK: - Definition gate (flipped by the durable slice)

    func testAllDefinitionsOfferDestructiveDeleteTools() {
        // gh#135 durable slice: the gate moved from the offering to
        // execution — the model IS offered the delete tools again; what it
        // can no longer do is mutate through them.
        let serializedNames = AgentTool.allDefinitions.map(\.name)
        XCTAssertTrue(serializedNames.contains("deleteTodo"),
                      "deleteTodo must be offered — staging, not omission, is the gate now")
        XCTAssertTrue(serializedNames.contains("deleteCalendarEvent"),
                      "deleteCalendarEvent must be offered — staging, not omission, is the gate now")
    }

    func testAllDefinitionsStillOfferNonDestructiveTools() {
        let serializedNames = AgentTool.allDefinitions.map(\.name)
        for expected in ["createTodo", "createCalendarEvent", "listTodos",
                         "listCalendarEvents", "updateTodo", "completeTodo",
                         "getScheduleForDate", "getUserData"] {
            XCTAssertTrue(serializedNames.contains(expected),
                          "non-destructive tool \(expected) must stay offered")
        }
    }

    // MARK: - Staging gate (the runner never mutates)

    func testExecuteStagesDeleteTodoWithoutMutatingStore() throws {
        let store = makeStore()
        let todo = seedTodo(into: store, title: "staging target")

        let raw = execute("deleteTodo", arguments: idArguments(todo.id), store: store)
        let object = try decodeJSONObject(raw)
        let result = try decodeResult(raw)

        XCTAssertTrue(store.events.contains { $0.id == todo.id },
                      "the todo must still be in the store — the runner stages, never deletes")
        XCTAssertTrue(result.success, "staging is a successful tool call: \(result.message)")
        XCTAssertTrue(result.message.contains("STAGED"),
                      "the model must be told the deletion is staged: \(result.message)")
        XCTAssertTrue(result.message.contains("confirmation"),
                      "the model must be told confirmation is the user's: \(result.message)")
        XCTAssertFalse(result.message.lowercased().contains("deleted todo"),
                       "the envelope must not claim the deletion happened: \(result.message)")
        XCTAssertEqual(object["staged"] as? Bool, true)

        let action = try XCTUnwrap(registry.pending, "staging must register a pending action")
        XCTAssertEqual(action.kind, .deleteTodo)
        XCTAssertEqual(action.eventID, todo.id)
        XCTAssertEqual(action.displayTitle, "staging target")
        XCTAssertNil(action.recurrenceScopeNote, "a plain todo carries no recurrence note")
    }

    func testExecuteStagesDeleteCalendarEventWithoutMutatingStore() throws {
        let store = makeStore()
        let event = seedCalendarEvent(into: store, title: "staging target")

        let raw = execute("deleteCalendarEvent", arguments: idArguments(event.id), store: store)
        let result = try decodeResult(raw)

        XCTAssertTrue(store.rawCalendarEvents.contains { $0.id == event.id },
                      "the calendar event must still be in the store — the runner stages, never deletes")
        XCTAssertTrue(result.success, "staging is a successful tool call: \(result.message)")
        XCTAssertTrue(result.message.contains("STAGED"),
                      "the model must be told the deletion is staged: \(result.message)")
        XCTAssertFalse(result.message.lowercased().contains("deleted calendar event"),
                       "the envelope must not claim the deletion happened: \(result.message)")

        let action = try XCTUnwrap(registry.pending, "staging must register a pending action")
        XCTAssertEqual(action.kind, .deleteCalendarEvent)
        XCTAssertEqual(action.eventID, event.id)
        XCTAssertEqual(action.displayTitle, "staging target")
        XCTAssertNotNil(action.displayTime, "a timed calendar event must show its slot on the card")
        XCTAssertNil(action.recurrenceScopeNote, "a plain event carries no recurrence note")
    }

    func testStagingUnknownTodoIdReportsNotFoundAndStagesNothing() throws {
        // The delete tools are legitimately offered now, so an unknown id
        // draws the same not-found shape as updateTodo — and must arm
        // nothing.
        let store = makeStore()

        let result = try decodeResult(execute("deleteTodo", arguments: idArguments(UUID()), store: store))

        XCTAssertFalse(result.success)
        XCTAssertTrue(result.message.contains("not found"),
                      "unknown id must draw the not-found error: \(result.message)")
        XCTAssertNil(registry.pending, "an unresolved target must never stage an action")
    }

    func testStagingUnknownCalendarEventIdReportsNotFoundAndStagesNothing() throws {
        let store = makeStore()

        let result = try decodeResult(execute("deleteCalendarEvent", arguments: idArguments(UUID()), store: store))

        XCTAssertFalse(result.success)
        XCTAssertTrue(result.message.contains("not found"),
                      "unknown id must draw the not-found error: \(result.message)")
        XCTAssertNil(registry.pending, "an unresolved target must never stage an action")
    }

    func testExecuteStillRunsNonDestructiveToolsOnSameStore() throws {
        // Positive control: staging is scoped to destructive cases — a
        // harmless mutation on the same store must go through, and must
        // never arm the registry.
        let store = makeStore()
        let todo = seedTodo(into: store, title: "complete me")

        let result = try decodeResult(execute("completeTodo", arguments: idArguments(todo.id), store: store))

        XCTAssertTrue(result.success, "non-destructive tool must still execute: \(result.message)")
        XCTAssertTrue(store.completedEvents.contains { $0.id == todo.id },
                      "completeTodo must have actually mutated the store")
        XCTAssertNil(registry.pending, "a non-destructive tool must never stage a pending action")
    }

    func testReplacingStagingEnvelopeNamesTheVoidedTarget() throws {
        // A model turn with TWO destructive calls must not read as two live
        // stagings: only one action can be pending, so the second envelope
        // must say it replaced the first — and NAME it — or the model relays
        // a staging that no longer exists.
        let store = makeStore()
        let first = seedTodo(into: store, title: "first target")
        let second = seedTodo(into: store, title: "second target")

        let firstResult = try decodeResult(execute("deleteTodo", arguments: idArguments(first.id), store: store))
        XCTAssertFalse(firstResult.message.contains("REPLACES"),
                       "the first staging replaced nothing: \(firstResult.message)")
        let firstNonce = try XCTUnwrap(registry.pending?.nonce)

        let secondResult = try decodeResult(execute("deleteTodo", arguments: idArguments(second.id), store: store))
        XCTAssertTrue(secondResult.message.contains("REPLACES"),
                      "a replacing staging must say so: \(secondResult.message)")
        XCTAssertTrue(secondResult.message.contains("first target"),
                      "the replacement notice must NAME the voided target: \(secondResult.message)")
        XCTAssertTrue(secondResult.message.contains("STAGED"),
                      "the replacement notice augments, not supplants, the staging notice: \(secondResult.message)")

        // The voided staging is dead: its nonce refuses, only the second awaits.
        let outcome = registry.confirm(nonce: firstNonce, store: store)
        guard case .refused = outcome else {
            return XCTFail("the replaced staging's nonce must refuse; got \(outcome)")
        }
        XCTAssertEqual(registry.pending?.eventID, second.id)
        XCTAssertTrue(store.events.contains { $0.id == first.id })
        XCTAssertTrue(store.events.contains { $0.id == second.id })
    }

    // MARK: - Staged card fields

    func testStagedSeriesTemplateCarriesWholeSeriesWarning() throws {
        let store = makeStore()
        let series = seedRecurringSeries(into: store, title: "daily standup")

        let result = try decodeResult(execute("deleteCalendarEvent", arguments: idArguments(series.id), store: store))
        XCTAssertTrue(result.success)

        XCTAssertTrue(store.rawCalendarEvents.contains { $0.id == series.id },
                      "staging a series template must not touch the store")
        let action = try XCTUnwrap(registry.pending)
        let note = try XCTUnwrap(action.recurrenceScopeNote,
                                 "a series-template target must carry the recurrence scope note")
        XCTAssertTrue(note.contains("ENTIRE series"),
                      "the note must say the whole series dies with the template: \(note)")
    }

    func testStagedDetachedInstanceCarriesSingleOccurrenceNote() throws {
        let store = makeStore()
        let series = seedRecurringSeries(into: store, title: "daily standup")
        let calendar = Calendar.current
        let occurrenceDay = calendar.startOfDay(for: Date())
        let instance = Event(
            title: "standup (moved)",
            timeRanges: [Event.TimeRange(start: Date(), end: Date().addingTimeInterval(1800))],
            recurrenceParentId: series.id,
            recurrenceInstanceDate: occurrenceDay,
            recurrenceInstanceDayKey: Event.recurrenceDayKey(for: occurrenceDay, calendar: calendar)
        )
        store.addCalendarEvent(instance)

        let result = try decodeResult(execute("deleteCalendarEvent", arguments: idArguments(instance.id), store: store))
        XCTAssertTrue(result.success)

        let action = try XCTUnwrap(registry.pending)
        let note = try XCTUnwrap(action.recurrenceScopeNote,
                                 "a detached-occurrence target must carry the recurrence scope note")
        XCTAssertTrue(note.contains("only this occurrence"),
                      "the note must scope the deletion to the one occurrence: \(note)")
    }

    /// gh#187 family: the card's display time is the DRAWN frame. Same
    /// fixture idiom as CalendarReadSideProjectionTests.makeTraveledInstance
    /// — detach an Apia-frame occurrence through the production seam, read
    /// under New York, where raw and projected sit a day apart.
    func testStagedDeleteCalendarEventDisplayTimeIsProjectedForTraveledInstance() throws {
        var apia = Calendar(identifier: .gregorian)
        apia.timeZone = TimeZone(identifier: "Pacific/Apia")!
        var ny = Calendar(identifier: .gregorian)
        ny.timeZone = TimeZone(identifier: "America/New_York")!

        func apiaDate(_ day: Int, _ hour: Int) -> Date {
            apia.date(from: DateComponents(year: 2026, month: 8, day: day, hour: hour))!
        }

        let series = Event(
            title: "Daily",
            timeRanges: [Event.TimeRange(start: apiaDate(3, 9), end: apiaDate(3, 10))],
            repeatUnit: .day,
            repeatInterval: 1
        )
        let edit = Event.applyEdit(
            series: series,
            occurrenceDate: apiaDate(10, 9),
            scope: .single,
            edit: { $0.title = "TraveledDetachedProbe" },
            calendar: apia
        )
        let instance = try XCTUnwrap(edit.exceptionInstance)
        let raw = try XCTUnwrap(instance.primaryTimeRange)
        let projected = try XCTUnwrap(instance.renderPrimaryTimeRange(calendar: ny))
        XCTAssertNotEqual(projected, raw,
                          "fixture must actually travel — identical frames make the assertion vacuous")

        let priorTimeZone = NSTimeZone.default
        NSTimeZone.default = TimeZone(identifier: "America/New_York")!
        defer { NSTimeZone.default = priorTimeZone }

        let store = makeStore()
        store.addCalendarEvent(instance)

        let result = try decodeResult(execute("deleteCalendarEvent", arguments: idArguments(instance.id), store: store))
        XCTAssertTrue(result.success)

        let display = DateFormatter()
        display.dateStyle = .medium
        display.timeStyle = .short

        let action = try XCTUnwrap(registry.pending)
        XCTAssertEqual(action.displayTime,
                       "\(display.string(from: projected.start)) – \(display.string(from: projected.end))",
                       "the card must name the slot the canvas draws")
        XCTAssertNotEqual(action.displayTime,
                          "\(display.string(from: raw.start)) – \(display.string(from: raw.end))",
                          "the raw string names an instant on a day the canvas draws nothing")
    }

    // MARK: - updateTodo deadline argument (gh#202)

    func testUpdateTodoNullDeadlineRemovesIt() throws {
        let store = makeStore()
        let todo = seedTodoWithDeadline(into: store, title: "deadline holder")
        XCTAssertNotNil(try storedTodo(store, todo.id).deadline,
                        "fixture must start with a deadline")

        let raw = execute(
            "updateTodo",
            arguments: "{\"id\": \"\(todo.id.uuidString)\", \"deadline\": null}",
            store: store
        )
        let result = try decodeResult(raw)

        XCTAssertTrue(result.success, "null is the documented removal mechanism: \(result.message)")
        XCTAssertTrue(result.message.contains("removed"),
                      "success message must say the deadline was removed: \(result.message)")
        XCTAssertNil(try storedTodo(store, todo.id).deadline,
                     "deadline must be gone from the store after deadline: null")
    }

    func testUpdateTodoGarbageDeadlineRejectsWholeUpdateAtomically() throws {
        let store = makeStore()
        let todo = seedTodoWithDeadline(into: store, title: "original title")

        let raw = execute(
            "updateTodo",
            arguments: "{\"id\": \"\(todo.id.uuidString)\", \"title\": \"smuggled title\", \"deadline\": \"not-a-date\"}",
            store: store
        )
        let result = try decodeResult(raw)

        XCTAssertFalse(result.success,
                       "garbage deadline must fail, never silently clear: \(result.message)")
        XCTAssertTrue(result.message.contains("yyyy-MM-dd"),
                      "failure must name the accepted format: \(result.message)")
        let stored = try storedTodo(store, todo.id)
        XCTAssertEqual(stored.deadline, fixtureDeadline,
                       "deadline must be untouched after a rejected update")
        XCTAssertEqual(stored.title, "original title",
                       "rejection is atomic: the valid title must NOT have been applied")
    }

    func testUpdateTodoAbsentDeadlineKeyLeavesDeadlineUntouched() throws {
        let store = makeStore()
        let todo = seedTodoWithDeadline(into: store, title: "keep my deadline")

        let raw = execute(
            "updateTodo",
            arguments: "{\"id\": \"\(todo.id.uuidString)\", \"title\": \"renamed\"}",
            store: store
        )
        let result = try decodeResult(raw)

        XCTAssertTrue(result.success, "title-only update must succeed: \(result.message)")
        let stored = try storedTodo(store, todo.id)
        XCTAssertEqual(stored.title, "renamed")
        XCTAssertEqual(stored.deadline, fixtureDeadline,
                       "absent deadline key must leave the deadline untouched")
    }

    func testUpdateTodoValidDeadlineStringSetsIt() throws {
        // Positive control for the rejection tests: the set path still works.
        let store = makeStore()
        let todo = seedTodo(into: store, title: "gets a deadline")

        let raw = execute(
            "updateTodo",
            arguments: "{\"id\": \"\(todo.id.uuidString)\", \"deadline\": \"2030-05-01T14:30:00\"}",
            store: store
        )
        let result = try decodeResult(raw)

        XCTAssertTrue(result.success, "valid deadline string must succeed: \(result.message)")
        let deadline = try XCTUnwrap(try storedTodo(store, todo.id).deadline,
                                     "deadline must have been set")
        // Assert components independently of the runner's own parser.
        let parts = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute], from: deadline)
        XCTAssertEqual(parts.year, 2030)
        XCTAssertEqual(parts.month, 5)
        XCTAssertEqual(parts.day, 1)
        XCTAssertEqual(parts.hour, 14)
        XCTAssertEqual(parts.minute, 30)
    }

    func testCreateTodoGarbageDeadlineRejectsAndCreatesNothing() throws {
        let store = makeStore()

        let raw = execute(
            "createTodo",
            arguments: "{\"title\": \"phantom\", \"deadline\": \"tomorrow-ish\"}",
            store: store
        )
        let result = try decodeResult(raw)

        XCTAssertFalse(result.success,
                       "garbage deadline must reject the create: \(result.message)")
        XCTAssertTrue(result.message.contains("yyyy-MM-dd"),
                      "failure must name the accepted format: \(result.message)")
        XCTAssertFalse(store.events.contains { $0.title == "phantom" },
                       "rejection is atomic: no todo may have been created")
    }

    func testCreateTodoValidDeadlineStringSetsIt() throws {
        // Positive control for the create-side rejection: a valid deadline
        // string must land on the created todo, not be dropped en route.
        let store = makeStore()

        let raw = execute(
            "createTodo",
            arguments: "{\"title\": \"carries deadline\", \"deadline\": \"2030-11-20T08:15:00\"}",
            store: store
        )
        let result = try decodeResult(raw)

        XCTAssertTrue(result.success, "valid deadline on create must succeed: \(result.message)")
        let created = try XCTUnwrap(store.events.first { $0.title == "carries deadline" })
        let deadline = try XCTUnwrap(created.deadline, "created todo must carry the deadline")
        // Assert components independently of the runner's own parser.
        let parts = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute], from: deadline)
        XCTAssertEqual(parts.year, 2030)
        XCTAssertEqual(parts.month, 11)
        XCTAssertEqual(parts.day, 20)
        XCTAssertEqual(parts.hour, 8)
        XCTAssertEqual(parts.minute, 15)
    }

    func testCreateTodoNullDeadlineCreatesWithoutDeadline() throws {
        // For a create there is nothing to remove — explicit null behaves
        // like an absent key rather than an error.
        let store = makeStore()

        let raw = execute(
            "createTodo",
            arguments: "{\"title\": \"no deadline\", \"deadline\": null}",
            store: store
        )
        let result = try decodeResult(raw)

        XCTAssertTrue(result.success, "null deadline on create must not error: \(result.message)")
        let created = try XCTUnwrap(store.events.first { $0.title == "no deadline" })
        XCTAssertNil(created.deadline)
    }
}

// MARK: - Registry (gh#135: the ONLY path from staged to deleted)

@MainActor
final class AgentPendingActionRegistryTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var location: EventStorageLocation!
    private var registry: AgentPendingActionRegistry!

    override func setUp() {
        super.setUp()
        suiteName = "AgentPendingActionRegistryTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        location = TestStorage.reset(suiteName)
        registry = AgentPendingActionRegistry()
    }

    override func tearDown() {
        TestStorage.tearDown(suiteName)
        defaults = nil
        suiteName = nil
        location = nil
        registry = nil
        super.tearDown()
    }

    private func makeStore() -> EventStore {
        EventStore(defaults: defaults, storage: location, seedsSampleDataIfEmpty: false)
    }

    /// Stages through the production gate — the same path the runner takes —
    /// so these tests exercise the real envelope, not a hand-built action.
    private func stageDelete(
        _ toolName: String,
        id: UUID,
        store: EventStore,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> AgentPendingDestructiveAction {
        let raw = AgentToolRunner.execute(
            toolName: toolName,
            arguments: "{\"id\": \"\(id.uuidString)\"}",
            store: store,
            pendingActions: registry
        )
        XCTAssertTrue(raw.contains("STAGED"), "staging must have succeeded: \(raw)", file: file, line: line)
        return try XCTUnwrap(registry.pending, "staging must arm the registry", file: file, line: line)
    }

    private func seedTodo(into store: EventStore, title: String) -> Event {
        let event = Event(title: title)
        store.addWithAutoPlacement(event)
        return event
    }

    func testConfirmWithinTTLDeletesTodoClearsRegistryAndReportsTitle() throws {
        let store = makeStore()
        let todo = seedTodo(into: store, title: "doomed todo")
        let action = try stageDelete("deleteTodo", id: todo.id, store: store)

        let outcome = registry.confirm(nonce: action.nonce, store: store)

        XCTAssertEqual(outcome, .deleted(title: "doomed todo"))
        XCTAssertFalse(store.events.contains { $0.id == todo.id },
                       "confirmation must actually delete the todo")
        XCTAssertNil(registry.pending, "a consumed action must leave the registry")
    }

    func testConfirmDeletesWholeSeriesIncludingMaterializedExceptions() throws {
        let store = makeStore()
        let start = Date()
        let series = Event(
            title: "daily standup",
            timeRanges: [Event.TimeRange(start: start, end: start.addingTimeInterval(1800))],
            repeatUnit: .day,
            repeatInterval: 1
        )
        store.addCalendarEvent(series)
        let calendar = Calendar.current
        let occurrenceDay = calendar.startOfDay(for: start)
        let exception = Event(
            title: "standup (moved)",
            timeRanges: [Event.TimeRange(start: start.addingTimeInterval(3600), end: start.addingTimeInterval(5400))],
            recurrenceParentId: series.id,
            recurrenceInstanceDate: occurrenceDay,
            recurrenceInstanceDayKey: Event.recurrenceDayKey(for: occurrenceDay, calendar: calendar)
        )
        store.addCalendarEvent(exception)

        let action = try stageDelete("deleteCalendarEvent", id: series.id, store: store)
        XCTAssertNotNil(action.recurrenceScopeNote, "series template must have been staged with the warning")

        let outcome = registry.confirm(nonce: action.nonce, store: store)

        XCTAssertEqual(outcome, .deleted(title: "daily standup"))
        XCTAssertFalse(store.rawCalendarEvents.contains { $0.id == series.id },
                       "the template must be gone")
        XCTAssertFalse(store.rawCalendarEvents.contains { $0.id == exception.id },
                       "the materialized exception must die with its series — the staged warning promised the ENTIRE series")
        XCTAssertNil(registry.pending)
    }

    func testCancelClearsRegistryWithoutMutation() throws {
        let store = makeStore()
        let todo = seedTodo(into: store, title: "survivor")
        let action = try stageDelete("deleteTodo", id: todo.id, store: store)

        let discarded = try XCTUnwrap(registry.cancel(nonce: action.nonce),
                                      "cancel with the staged nonce must return the discarded action")
        XCTAssertEqual(discarded.displayTitle, "survivor")

        XCTAssertNil(registry.pending, "cancel must clear the registry")
        XCTAssertTrue(store.events.contains { $0.id == todo.id },
                      "cancel must never touch the store")
    }

    func testExpiredConfirmRefusesAndDoesNotMutate() throws {
        let store = makeStore()
        let todo = seedTodo(into: store, title: "survivor")
        let action = try stageDelete("deleteTodo", id: todo.id, store: store)

        let afterExpiry = action.createdAt.addingTimeInterval(action.timeToLive + 1)
        let outcome = registry.confirm(nonce: action.nonce, store: store, now: afterExpiry)

        guard case .refused(let reason) = outcome else {
            return XCTFail("an expired confirmation must refuse; got \(outcome)")
        }
        XCTAssertTrue(reason.contains("expired"), "the refusal must say why: \(reason)")
        XCTAssertTrue(store.events.contains { $0.id == todo.id },
                      "an expired confirmation must never delete")
        XCTAssertNil(registry.pending, "an expired action is disarmed, not left ticking")
    }

    func testWrongNonceConfirmRefusesAndDoesNotMutate() throws {
        let store = makeStore()
        let todo = seedTodo(into: store, title: "survivor")
        _ = try stageDelete("deleteTodo", id: todo.id, store: store)

        let outcome = registry.confirm(nonce: UUID(), store: store)

        guard case .refused = outcome else {
            return XCTFail("a mismatched nonce must refuse; got \(outcome)")
        }
        XCTAssertTrue(store.events.contains { $0.id == todo.id },
                      "a mismatched nonce must never delete")
        XCTAssertNotNil(registry.pending,
                        "a mismatched confirm must not disarm the genuinely staged action")
    }

    func testConfirmAfterTargetVanishedRefusesGracefully() throws {
        let store = makeStore()
        let todo = seedTodo(into: store, title: "gone by then")
        let bystander = seedTodo(into: store, title: "bystander")
        let action = try stageDelete("deleteTodo", id: todo.id, store: store)

        // The user deletes the todo manually before confirming.
        store.delete(todo)

        let outcome = registry.confirm(nonce: action.nonce, store: store)

        guard case .refused(let reason) = outcome else {
            return XCTFail("a vanished target must refuse; got \(outcome)")
        }
        XCTAssertTrue(reason.contains("no longer exists"), "the refusal must say why: \(reason)")
        XCTAssertTrue(store.events.contains { $0.id == bystander.id },
                      "nothing else may be deleted in its place")
        XCTAssertNil(registry.pending)
    }

    func testStagingReplacesPriorActionAndOldNonceCannotConfirm() throws {
        let store = makeStore()
        let first = seedTodo(into: store, title: "first target")
        let second = seedTodo(into: store, title: "second target")

        let firstAction = try stageDelete("deleteTodo", id: first.id, store: store)
        let secondAction = try stageDelete("deleteTodo", id: second.id, store: store)
        XCTAssertEqual(registry.pending?.eventID, second.id,
                       "a new staging replaces the prior pending action")

        guard case .refused = registry.confirm(nonce: firstAction.nonce, store: store) else {
            return XCTFail("the replaced action's nonce must no longer confirm anything")
        }
        XCTAssertTrue(store.events.contains { $0.id == first.id })
        XCTAssertTrue(store.events.contains { $0.id == second.id })

        XCTAssertEqual(registry.confirm(nonce: secondAction.nonce, store: store),
                       .deleted(title: "second target"))
        XCTAssertFalse(store.events.contains { $0.id == second.id })
        XCTAssertTrue(store.events.contains { $0.id == first.id },
                      "only the confirmed target dies")
    }

    func testConfirmRefusesWhenTargetShapeChangedSinceStaging() throws {
        // Consent covers the card AS RENDERED. A plain event that gains a
        // repeat rule inside the TTL would otherwise confirm into a
        // whole-series delete the card never described.
        let store = makeStore()
        let start = Date()
        let event = Event(
            title: "gains a repeat rule",
            timeRanges: [Event.TimeRange(start: start, end: start.addingTimeInterval(3600))]
        )
        store.addCalendarEvent(event)
        let action = try stageDelete("deleteCalendarEvent", id: event.id, store: store)
        XCTAssertFalse(action.wasRecurringSeries, "fixture stages the PLAIN shape")
        XCTAssertNil(action.recurrenceScopeNote, "the card showed no series warning")

        var mutated = try XCTUnwrap(store.rawCalendarEvents.first { $0.id == event.id })
        mutated.repeatUnit = .day
        store.updateCalendarEvent(mutated)
        XCTAssertTrue(try XCTUnwrap(store.rawCalendarEvents.first { $0.id == event.id }).isRecurringSeries,
                      "fixture must actually change the live shape")

        let outcome = registry.confirm(nonce: action.nonce, store: store)

        guard case .refused(let reason) = outcome else {
            return XCTFail("a shape change must refuse; got \(outcome)")
        }
        XCTAssertTrue(reason.contains("changed"), "the refusal must say why: \(reason)")
        XCTAssertTrue(store.rawCalendarEvents.contains { $0.id == event.id },
                      "nothing may be deleted on a shape mismatch")
    }

    func testServiceConfirmUsesRenderedCardNonceNotCurrentPending() throws {
        // R135B-1: the service takes the nonce of the card the user SAW.
        // Wiring it to re-read the registry's current pending at tap time
        // makes the nonce guard vacuous — a Confirm consented to card A
        // would execute a just-replaced staging B.
        let store = makeStore()
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("AgentPendingActionRegistryTests-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = AgentService(
            repository: AgentConversationRepository(directory: directory, legacyDefaults: nil)
        )
        service.eventStore = store

        let cardA = seedTodo(into: store, title: "card A")
        let cardB = seedTodo(into: store, title: "card B")

        // Stage A into the service's own registry and capture the nonce its
        // card rendered; then B replaces it before the tap lands.
        _ = AgentToolRunner.execute(
            toolName: "deleteTodo",
            arguments: "{\"id\": \"\(cardA.id.uuidString)\"}",
            store: store,
            pendingActions: service.pendingDestructiveActions
        )
        let renderedNonce = try XCTUnwrap(service.pendingDestructiveActions.pending?.nonce)
        _ = AgentToolRunner.execute(
            toolName: "deleteTodo",
            arguments: "{\"id\": \"\(cardB.id.uuidString)\"}",
            store: store,
            pendingActions: service.pendingDestructiveActions
        )

        service.confirmPendingDestructiveAction(nonce: renderedNonce)

        XCTAssertTrue(store.events.contains { $0.id == cardA.id },
                      "A's staging was voided — nothing may die from the stale tap")
        XCTAssertTrue(store.events.contains { $0.id == cardB.id },
                      "B was never consented — the stale tap must not execute it")
        XCTAssertEqual(service.pendingDestructiveActions.pending?.eventID, cardB.id,
                       "B stays staged, awaiting a real decision")
        let lastMessage = try XCTUnwrap(service.messages.last)
        XCTAssertTrue(lastMessage.content.contains("no longer matches"),
                      "the user is told the tap went stale: \(lastMessage.content)")

        // The stale Cancel is equally inert.
        service.cancelPendingDestructiveAction(nonce: renderedNonce)
        XCTAssertEqual(service.pendingDestructiveActions.pending?.eventID, cardB.id,
                       "a stale cancel must not discard B")
    }
}
