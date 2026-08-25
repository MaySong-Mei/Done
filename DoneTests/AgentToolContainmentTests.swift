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
}
