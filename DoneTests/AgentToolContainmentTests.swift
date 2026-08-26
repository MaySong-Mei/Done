//
//  AgentToolContainmentTests.swift
//  DoneTests
//
//  gh#135: the agent's destructive tools (deleteTodo, deleteCalendarEvent)
//  executed hard deletes with zero confirmation. Containment is two gates
//  over one predicate (`AgentTool.isDestructive`):
//
//  - definition gate: `allDefinitions` never serializes a destructive tool,
//    so the model is never offered one;
//  - runner gate: `AgentToolRunner.execute` refuses a destructive tool called
//    by name, BEFORE any store lookup or mutation — a model can hallucinate
//    a tool it was never offered, so hiding the definition alone is not
//    containment.
//
//  Both gates carry a positive control: the filter must not over-block, and
//  the refusal must be scoped to destructive cases only.
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

    override func setUp() {
        super.setUp()
        suiteName = "AgentToolContainmentTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        location = TestStorage.reset(suiteName)
    }

    override func tearDown() {
        TestStorage.tearDown(suiteName)
        defaults = nil
        suiteName = nil
        location = nil
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

    /// Decodes the runner's jsonResult envelope without `try!`.
    private func decodeResult(
        _ raw: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> (success: Bool, message: String) {
        let data = try XCTUnwrap(raw.data(using: .utf8), "result not UTF-8: \(raw)", file: file, line: line)
        let object = try XCTUnwrap(
            (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            "result not a JSON object: \(raw)", file: file, line: line
        )
        let success = try XCTUnwrap(object["success"] as? Bool, "missing success: \(raw)", file: file, line: line)
        let message = try XCTUnwrap(object["message"] as? String, "missing message: \(raw)", file: file, line: line)
        return (success, message)
    }

    private func idArguments(_ id: UUID) -> String {
        "{\"id\": \"\(id.uuidString)\"}"
    }

    // MARK: - Definition gate

    func testAllDefinitionsOmitDestructiveToolNames() {
        let serializedNames = AgentTool.allDefinitions.map(\.name)
        XCTAssertFalse(serializedNames.contains("deleteTodo"),
                       "deleteTodo must never be offered to the model")
        XCTAssertFalse(serializedNames.contains("deleteCalendarEvent"),
                       "deleteCalendarEvent must never be offered to the model")
    }

    func testAllDefinitionsStillOfferNonDestructiveTools() {
        let serializedNames = AgentTool.allDefinitions.map(\.name)
        for expected in ["createTodo", "createCalendarEvent", "listTodos",
                         "listCalendarEvents", "updateTodo", "completeTodo",
                         "getScheduleForDate", "getUserData"] {
            XCTAssertTrue(serializedNames.contains(expected),
                          "non-destructive tool \(expected) must stay offered — the filter over-blocked")
        }
    }

    // MARK: - Runner gate

    func testExecuteRefusesDeleteTodoAndTodoSurvives() throws {
        let store = makeStore()
        let todo = seedTodo(into: store, title: "containment target")

        let raw = AgentToolRunner.execute(
            toolName: "deleteTodo",
            arguments: idArguments(todo.id),
            store: store
        )
        let result = try decodeResult(raw)

        XCTAssertFalse(result.success)
        XCTAssertTrue(result.message.contains("requires in-app confirmation"),
                      "refusal must be the containment message, not a lookup failure: \(result.message)")
        XCTAssertTrue(store.events.contains { $0.id == todo.id },
                      "todo must still be in the store after the refused call")
    }

    func testExecuteRefusesDeleteCalendarEventAndEventSurvives() throws {
        let store = makeStore()
        let event = seedCalendarEvent(into: store, title: "containment target")

        let raw = AgentToolRunner.execute(
            toolName: "deleteCalendarEvent",
            arguments: idArguments(event.id),
            store: store
        )
        let result = try decodeResult(raw)

        XCTAssertFalse(result.success)
        XCTAssertTrue(result.message.contains("requires in-app confirmation"),
                      "refusal must be the containment message, not a lookup failure: \(result.message)")
        XCTAssertTrue(store.rawCalendarEvents.contains { $0.id == event.id },
                      "calendar event must still be in the store after the refused call")
    }

    func testRefusalPrecedesStoreLookup() throws {
        // A nonexistent id must still draw the containment refusal, not
        // "not found" — proof the gate fires before any store lookup.
        let store = makeStore()

        let raw = AgentToolRunner.execute(
            toolName: "deleteTodo",
            arguments: idArguments(UUID()),
            store: store
        )
        let result = try decodeResult(raw)

        XCTAssertFalse(result.success)
        XCTAssertTrue(result.message.contains("requires in-app confirmation"),
                      "gate must fire before lookup; got: \(result.message)")
    }

    func testRefusalPrecedesStoreLookupForCalendarEvent() throws {
        // Calendar twin of the ordering witness: a well-formed nonexistent
        // id must draw the containment refusal, never "not found".
        let store = makeStore()

        let raw = AgentToolRunner.execute(
            toolName: "deleteCalendarEvent",
            arguments: idArguments(UUID()),
            store: store
        )
        let result = try decodeResult(raw)

        XCTAssertFalse(result.success)
        XCTAssertTrue(result.message.contains("requires in-app confirmation"),
                      "gate must fire before lookup; got: \(result.message)")
        XCTAssertFalse(result.message.contains("not found"),
                       "a lookup-first refusal leaks existence info; got: \(result.message)")
    }

    func testExecuteStillRunsNonDestructiveToolsOnSameStore() throws {
        // Positive control: the refusal is scoped to destructive cases —
        // a harmless mutation on the same store must go through.
        let store = makeStore()
        let todo = seedTodo(into: store, title: "complete me")

        let raw = AgentToolRunner.execute(
            toolName: "completeTodo",
            arguments: idArguments(todo.id),
            store: store
        )
        let result = try decodeResult(raw)

        XCTAssertTrue(result.success, "non-destructive tool must still execute: \(result.message)")
        XCTAssertTrue(store.completedEvents.contains { $0.id == todo.id },
                      "completeTodo must have actually mutated the store")
    }

    // MARK: - updateTodo deadline argument (gh#202)

    func testUpdateTodoNullDeadlineRemovesIt() throws {
        let store = makeStore()
        let todo = seedTodoWithDeadline(into: store, title: "deadline holder")
        XCTAssertNotNil(try storedTodo(store, todo.id).deadline,
                        "fixture must start with a deadline")

        let raw = AgentToolRunner.execute(
            toolName: "updateTodo",
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

        let raw = AgentToolRunner.execute(
            toolName: "updateTodo",
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

        let raw = AgentToolRunner.execute(
            toolName: "updateTodo",
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

        let raw = AgentToolRunner.execute(
            toolName: "updateTodo",
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

        let raw = AgentToolRunner.execute(
            toolName: "createTodo",
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

        let raw = AgentToolRunner.execute(
            toolName: "createTodo",
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

        let raw = AgentToolRunner.execute(
            toolName: "createTodo",
            arguments: "{\"title\": \"no deadline\", \"deadline\": null}",
            store: store
        )
        let result = try decodeResult(raw)

        XCTAssertTrue(result.success, "null deadline on create must not error: \(result.message)")
        let created = try XCTUnwrap(store.events.first { $0.title == "no deadline" })
        XCTAssertNil(created.deadline)
    }
}
