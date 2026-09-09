//
//  MacComposerTodoTests.swift
//  DoneMacTests
//
//  Budget assertion 5 (a keystroke's bill is confined to the composer)
//  plus the composer's seeded-write passthrough and the todo drawer's
//  recipient scoping.
//

import XCTest
@testable import Done

@MainActor
final class MacComposerTodoTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    private let dayStart = Date(timeIntervalSince1970: 1_773_100_800)  // 2026-03-10 UTC
    private var day10: DayKey { DayKey(year: 2026, month: 3, day: 10) }

    private struct Rig {
        let store: MacEventStore
        let surface: CalendarSurfaceModel
        let todos: TodoSurfaceModel
        let composer: ComposerModel
        let bill: MacWorkBill
    }

    private func makeRig(events: [Event] = []) async throws -> Rig {
        let bill = MacWorkBill()
        let persistence = try MacPersistence(location: .ephemeral(id: UUID()))
        let store = MacEventStore(persistence: persistence, bill: bill, calendar: calendar)
        await store.load()
        for event in events { store.addCalendarEvent(event, now: dayStart) }
        let clock = ClockHub(calendar: calendar, bill: bill, drivesTimer: false)
        let surface = CalendarSurfaceModel(
            store: store, clock: clock, calendar: calendar, bill: bill,
            anchor: dayStart, dayCount: 7
        )
        surface.activate(now: dayStart)
        let todos = TodoSurfaceModel(store: store, bill: bill)
        todos.activate()
        return Rig(store: store, surface: surface, todos: todos,
                   composer: ComposerModel(store: store, calendar: calendar), bill: bill)
    }

    private func event(id: UUID = UUID(), title: String = "E", hour: Double) -> Event {
        let start = dayStart.addingTimeInterval(hour * 3600)
        return Event(id: id, title: title,
                     timeRanges: [.init(start: start, end: start.addingTimeInterval(3600))],
                     kind: .event)
    }

    /// BUDGET ASSERTION 5: ten keystrokes cost the store and the canvas
    /// exactly nothing; the save is one commit.
    func testTypingBudget() async throws {
        let id = UUID()
        let rig = try await makeRig(events: [event(id: id, title: "Before", hour: 9)])
        XCTAssertTrue(rig.composer.openForEdit(eventID: id, now: dayStart))
        let commits = rig.bill.count(.storeCommits)
        let builds = rig.bill.count(.dayModelBuilds)
        let rebuilds = rig.bill.count(.surfaceRebuilds)

        for ch in "TypedTitle" { rig.composer.title.append(ch) }

        XCTAssertEqual(rig.bill.count(.storeCommits), commits, "a keystroke committed")
        XCTAssertEqual(rig.bill.count(.dayModelBuilds), builds, "a keystroke rebuilt a day model")
        XCTAssertEqual(rig.bill.count(.surfaceRebuilds), rebuilds, "a keystroke reached the canvas surface")

        rig.composer.save(now: dayStart)
        XCTAssertEqual(rig.bill.count(.storeCommits) - commits, 1)
        XCTAssertEqual(rig.store.calendarEvents.first { $0.id == id }?.title, "BeforeTypedTitle")
    }

    /// The write-side seeding rule's passthrough half: saving with times
    /// untouched round-trips timeRanges bit-identical to the SEEDED
    /// projection — never a re-derived instant.
    func testUntouchedTimesPassThroughBitIdentical() async throws {
        let id = UUID()
        let original = event(id: id, title: "Keep", hour: 9)
        let rig = try await makeRig(events: [original])
        XCTAssertTrue(rig.composer.openForEdit(eventID: id, now: dayStart))
        rig.composer.title = "Renamed"
        rig.composer.save(now: dayStart)
        let saved = rig.store.calendarEvents.first { $0.id == id }
        XCTAssertEqual(saved?.timeRanges, original.renderTimeRanges(calendar: calendar),
                       "untouched time fields must round-trip the seeded ranges verbatim")
        XCTAssertEqual(saved?.title, "Renamed")
    }

    func testEditedStartWritesTheEditedRange() async throws {
        let id = UUID()
        let rig = try await makeRig(events: [event(id: id, hour: 9)])
        XCTAssertTrue(rig.composer.openForEdit(eventID: id, now: dayStart))
        rig.composer.start = dayStart.addingTimeInterval(13 * 3600)
        rig.composer.end = dayStart.addingTimeInterval(14 * 3600)
        rig.composer.save(now: dayStart)
        let saved = rig.store.calendarEvents.first { $0.id == id }
        XCTAssertEqual(saved?.timeRanges.first?.start, dayStart.addingTimeInterval(13 * 3600))
    }

    func testCreateAndDeleteThroughComposer() async throws {
        let rig = try await makeRig()
        rig.composer.openForCreate(day: day10, now: dayStart)
        rig.composer.title = "Made here"
        rig.composer.save(now: dayStart)
        guard let created = rig.store.calendarEvents.first else {
            return XCTFail("composer create landed nothing")
        }
        XCTAssertEqual(created.title, "Made here")

        XCTAssertTrue(rig.composer.openForEdit(eventID: created.id, now: dayStart))
        rig.composer.delete(now: dayStart)
        XCTAssertTrue(rig.store.calendarEvents.isEmpty)
    }

    func testReturnToStackPreservesDeadline() async throws {
        let id = UUID()
        let deadline = dayStart.addingTimeInterval(30 * 86_400)
        var todo = event(id: id, title: "Scheduled todo", hour: 9)
        todo.kind = .todo
        todo.deadline = deadline
        let rig = try await makeRig(events: [todo])
        XCTAssertFalse(rig.todos.rows.contains { $0.id == id }, "scheduled todo is not in the stack")

        XCTAssertTrue(rig.composer.openForEdit(eventID: id, now: dayStart))
        rig.composer.returnToStack(now: dayStart)

        let back = rig.store.calendarEvents.first { $0.id == id }
        XCTAssertEqual(back?.timeRanges, [], "unscheduling drops ranges")
        XCTAssertEqual(back?.deadline, deadline, "the commitment survives unscheduling")
        XCTAssertTrue(rig.todos.rows.contains { $0.id == id }, "it re-enters the stack")
    }

    func testTodoDrawerListsAddsAndScopes() async throws {
        let rig = try await makeRig()
        rig.todos.addTodo(title: "  Buy milk  ", now: dayStart)
        XCTAssertEqual(rig.todos.rows.map(\.title), ["Buy milk"])

        // An unrelated timed event must not rebuild the drawer — asserted
        // on the drawer's OWN counter (review round-3 F8: the shared
        // counter made this a guaranteed mutation survivor).
        let rebuilds = rig.bill.count(.todoSurfaceRebuilds)
        rig.store.addCalendarEvent(event(title: "Unrelated", hour: 15), now: dayStart)
        XCTAssertEqual(rig.bill.count(.todoSurfaceRebuilds), rebuilds,
                       "recipient scoping: the drawer never hears an unrelated timed commit")
        XCTAssertEqual(rig.todos.rows.map(\.title), ["Buy milk"])
    }

    func testEmptyTitleTodoStillLands() async throws {
        let rig = try await makeRig()
        rig.todos.addTodo(title: "   ", now: dayStart)
        XCTAssertEqual(rig.todos.rows.count, 1,
                       "data preservation: an empty title is a record, not a refusal")
    }
}
