//
//  AgendaSyncTests.swift
//  DoneTests
//
//  Test event synchronization between Calendar and Agenda views
//

import XCTest
@testable import Done

@MainActor
final class AgendaSyncTests: XCTestCase {
    var store: EventStore!
    let calendar = Calendar.current

    override func setUp() async throws {
        try await super.setUp()
        store = EventStore()
    }

    override func tearDown() async throws {
        store = nil
        try await super.tearDown()
    }

    // Test: Creating an event in Calendar should appear in Agenda
    func testCalendarEventAppearsInAgenda() {
        // Given: Create an event with a time range (calendar event)
        let today = calendar.startOfDay(for: Date())
        let startTime = calendar.date(byAdding: .hour, value: 10, to: today)!
        let endTime = calendar.date(byAdding: .hour, value: 11, to: today)!

        let event = Event(
            title: "Test Meeting",
            note: "Test note",
            startTime: startTime,
            endTime: endTime,
            timeRanges: [Event.TimeRange(start: startTime, end: endTime)],
            type: "Work"
        )

        // When: Add event to store
        store.addCalendarEvent(event)

        // Then: Event should exist in store
        XCTAssertEqual(store.calendarEvents.count, 1, "Event should be added to store")
        XCTAssertEqual(store.calendarEvents.first?.title, "Test Meeting")

        // And: Event should be visible in agenda for today
        let agendaEvents = eventsForDate(today, in: store)
        XCTAssertEqual(agendaEvents.count, 1, "Event should appear in agenda")
        XCTAssertEqual(agendaEvents.first?.title, "Test Meeting")
    }

    // Test: Todo events (without time ranges) should NOT appear in Agenda
    func testTodoEventDoesNotAppearInAgenda() {
        // Given: Create a todo event without time ranges
        let todoEvent = Event(
            title: "Todo Task",
            note: "This is a todo",
            timeRanges: [], // No time ranges
            type: "Work"
        )

        // When: Add event to store (todos go to events, not calendarEvents)
        store.add(todoEvent)

        // Then: Event should exist in store
        XCTAssertEqual(store.events.count, 1)

        // And: Event should NOT appear in agenda
        let today = calendar.startOfDay(for: Date())
        let agendaEvents = eventsForDate(today, in: store)
        XCTAssertEqual(agendaEvents.count, 0, "Todo events should not appear in agenda")
    }

    // Test: Multi-day events should appear on all relevant dates
    func testMultiDayEventAppearsOnMultipleDates() {
        // Given: Create an event spanning 3 days
        let today = calendar.startOfDay(for: Date())
        let startTime = calendar.date(byAdding: .hour, value: 10, to: today)!
        let endTime = calendar.date(byAdding: .day, value: 2, to: startTime)!

        let event = Event(
            title: "Conference",
            note: "Multi-day event",
            startTime: startTime,
            endTime: endTime,
            timeRanges: [Event.TimeRange(start: startTime, end: endTime)],
            type: "Work"
        )

        // When: Add event to store
        store.addCalendarEvent(event)

        // Then: Event should appear on all 3 days
        for dayOffset in 0...2 {
            let date = calendar.date(byAdding: .day, value: dayOffset, to: today)!
            let agendaEvents = eventsForDate(date, in: store)
            XCTAssertEqual(
                agendaEvents.count,
                1,
                "Event should appear on day \(dayOffset)"
            )
            XCTAssertEqual(agendaEvents.first?.title, "Conference")
        }

        // And: Should NOT appear on day before or after
        let dayBefore = calendar.date(byAdding: .day, value: -1, to: today)!
        let dayAfter = calendar.date(byAdding: .day, value: 3, to: today)!
        XCTAssertEqual(eventsForDate(dayBefore, in: store).count, 0)
        XCTAssertEqual(eventsForDate(dayAfter, in: store).count, 0)
    }

    // Test: Events are sorted by start time
    func testEventsAreSortedByStartTime() {
        // Given: Create 3 events with different start times
        let today = calendar.startOfDay(for: Date())

        let event1 = Event(
            title: "Lunch",
            startTime: calendar.date(byAdding: .hour, value: 12, to: today),
            endTime: calendar.date(byAdding: .hour, value: 13, to: today),
            timeRanges: [Event.TimeRange(
                start: calendar.date(byAdding: .hour, value: 12, to: today)!,
                end: calendar.date(byAdding: .hour, value: 13, to: today)!
            )],
            type: "Personal"
        )

        let event2 = Event(
            title: "Morning Meeting",
            startTime: calendar.date(byAdding: .hour, value: 9, to: today),
            endTime: calendar.date(byAdding: .hour, value: 10, to: today),
            timeRanges: [Event.TimeRange(
                start: calendar.date(byAdding: .hour, value: 9, to: today)!,
                end: calendar.date(byAdding: .hour, value: 10, to: today)!
            )],
            type: "Work"
        )

        let event3 = Event(
            title: "Evening Call",
            startTime: calendar.date(byAdding: .hour, value: 18, to: today),
            endTime: calendar.date(byAdding: .hour, value: 19, to: today),
            timeRanges: [Event.TimeRange(
                start: calendar.date(byAdding: .hour, value: 18, to: today)!,
                end: calendar.date(byAdding: .hour, value: 19, to: today)!
            )],
            type: "Work"
        )

        // When: Add events in random order
        store.addCalendarEvent(event1)
        store.addCalendarEvent(event3)
        store.addCalendarEvent(event2)

        // Then: Agenda should show them sorted by start time
        let agendaEvents = eventsForDate(today, in: store)
        XCTAssertEqual(agendaEvents.count, 3)
        XCTAssertEqual(agendaEvents[0].title, "Morning Meeting")
        XCTAssertEqual(agendaEvents[1].title, "Lunch")
        XCTAssertEqual(agendaEvents[2].title, "Evening Call")
    }

    // Test: Event updated in store reflects in agenda
    func testEventUpdateReflectsInAgenda() {
        // Given: Create an event
        let today = calendar.startOfDay(for: Date())
        let startTime = calendar.date(byAdding: .hour, value: 10, to: today)!
        let endTime = calendar.date(byAdding: .hour, value: 11, to: today)!

        var event = Event(
            title: "Original Title",
            startTime: startTime,
            endTime: endTime,
            timeRanges: [Event.TimeRange(start: startTime, end: endTime)],
            type: "Work"
        )

        store.addCalendarEvent(event)

        // When: Update the event
        event.title = "Updated Title"
        store.updateCalendarEvent(event)

        // Then: Updated event should appear in agenda
        let agendaEvents = eventsForDate(today, in: store)
        XCTAssertEqual(agendaEvents.count, 1)
        XCTAssertEqual(agendaEvents.first?.title, "Updated Title")
    }

    // Test: Deleted event should not appear in agenda
    func testDeletedEventDoesNotAppearInAgenda() {
        // Given: Create an event
        let today = calendar.startOfDay(for: Date())
        let startTime = calendar.date(byAdding: .hour, value: 10, to: today)!
        let endTime = calendar.date(byAdding: .hour, value: 11, to: today)!

        let event = Event(
            title: "To Be Deleted",
            startTime: startTime,
            endTime: endTime,
            timeRanges: [Event.TimeRange(start: startTime, end: endTime)],
            type: "Work"
        )

        store.addCalendarEvent(event)
        XCTAssertEqual(eventsForDate(today, in: store).count, 1)

        // When: Delete the event
        store.deleteCalendarEvent(event)

        // Then: Event should not appear in agenda
        let agendaEvents = eventsForDate(today, in: store)
        XCTAssertEqual(agendaEvents.count, 0, "Deleted event should not appear")
    }

    // Helper function that replicates the Agenda view's filtering logic
    private func eventsForDate(_ date: Date, in store: EventStore) -> [Event] {
        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart

        // Get calendar events from the calendarEvents list
        let filteredEvents = store.calendarEvents.filter { event in
            guard !event.timeRanges.isEmpty else { return false }

            // Check if any time range intersects this day
            return event.timeRanges.contains { range in
                range.start < dayEnd && range.end > dayStart
            }
        }

        // Sort by start time
        return filteredEvents.sorted { a, b in
            guard let aStart = a.timeRanges.first?.start,
                  let bStart = b.timeRanges.first?.start else {
                return false
            }
            return aStart < bStart
        }
    }
}
