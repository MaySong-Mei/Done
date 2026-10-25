//
//  MacReflectionTests.swift
//  DoneMacTests
//
//  The inspector's Reflection page writes what the phone's Reflection page
//  reads: completion, signals and the reflection note on the occurrence's
//  log record; images on the event's intake (customizing a series day).
//

import XCTest
@testable import Done

@MainActor
final class MacReflectionTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_773_133_200)   // 2026-03-10 09:00 UTC

    private func makeRig(_ event: Event) async -> (MacEventStore, EventInspectorModel) {
        let store = MacTestStore.make()
        await store.load()
        store.addCalendarEvent(event, now: start)
        let inspector = EventInspectorModel(store: store, calendar: .current)
        return (store, inspector)
    }

    private func plainEvent() -> Event {
        Event(id: UUID(), title: "Gym", timeRanges: [.init(start: start, end: start.addingTimeInterval(3600))],
              kind: .event)
    }

    func testCompletionDefaultsToCompletedAndWritesTheRecord() async throws {
        let event = plainEvent()
        let (store, inspector) = await makeRig(event)
        inspector.select(event.id)
        let occurrence = try XCTUnwrap(inspector.occurrence)
        let reflection = inspector.reflection(for: occurrence)
        XCTAssertEqual(reflection.completionStatus, .completed, "the phone's shown default")
        XCTAssertNil(store.shared.logRecord(for: occurrence))
        reflection.setCompletion(.partial)
        XCTAssertEqual(store.shared.prefilledDraft(for: occurrence).completionStatus, .partial)
        XCTAssertEqual(reflection.completionStatus, .partial)
    }

    func testSignalsToggleByIntent() async throws {
        let event = plainEvent()
        let (store, inspector) = await makeRig(event)
        inspector.select(event.id)
        let occurrence = try XCTUnwrap(inspector.occurrence)
        let reflection = inspector.reflection(for: occurrence)
        let calm = CalendarEmotionTag.calm.rawValue
        let deep = CalendarBehaviorTag.deepWork.rawValue
        reflection.toggle(.emotions, tagID: calm, targetSelected: true)
        reflection.toggle(.behaviors, tagID: deep, targetSelected: true)
        XCTAssertEqual(store.shared.prefilledDraft(for: occurrence).emotions, [calm])
        XCTAssertEqual(store.shared.prefilledDraft(for: occurrence).behaviors, [deep])
        // An OFF intent on a tag that is already off is a no-op, never a flip.
        reflection.toggle(.emotions, tagID: CalendarEmotionTag.happy.rawValue, targetSelected: false)
        XCTAssertEqual(reflection.emotions, [calm])
        reflection.toggle(.emotions, tagID: calm, targetSelected: false)
        XCTAssertEqual(reflection.emotions, [])
    }

    func testNoteWritesThroughAndReloads() async throws {
        let event = plainEvent()
        let (store, inspector) = await makeRig(event)
        inspector.select(event.id)
        let occurrence = try XCTUnwrap(inspector.occurrence)
        let reflection = inspector.reflection(for: occurrence)
        reflection.noteText = "Legs were heavy  "
        XCTAssertEqual(store.shared.logRecord(for: occurrence)?.note, "Legs were heavy",
                       "in memory at once (the disk commit is the debounced part)")
        reflection.flush()
        XCTAssertTrue(store.shared.flushPendingLogRecordCommit(), "nothing left pending after flush")
        // A fresh pane on the same occurrence loads the saved note.
        let reopened = InspectorReflectionModel(occurrence: occurrence, store: store.shared)
        XCTAssertEqual(reopened.noteText, "Legs were heavy")
    }

    /// The effort the Reflection page shows is the record's, shared with
    /// the overview dots.
    func testEffortAndCompletionShareOneRecord() async throws {
        let event = plainEvent()
        let (store, inspector) = await makeRig(event)
        inspector.select(event.id)
        let occurrence = try XCTUnwrap(inspector.occurrence)
        inspector.setEffort(id: event.id, 4, now: start)
        inspector.reflection(for: occurrence).setCompletion(.skipped)
        let record = try XCTUnwrap(store.shared.logRecord(for: occurrence))
        XCTAssertEqual(record.effort, 4)
        XCTAssertEqual(record.completionStatus, .skipped)
    }

    func testImagesLandOnTheEventIntake() async throws {
        let event = plainEvent()
        let (store, inspector) = await makeRig(event)
        inspector.select(event.id)
        let ref = AgenticIntakeImageRef(relativePath: "x/y.jpg", pixelWidth: 1, pixelHeight: 1, fileSizeBytes: 1)
        inspector.setIntakeImages(id: event.id, [ref], now: start)
        XCTAssertEqual(store.calendarEvents.first { $0.id == event.id }?.agenticIntake?.images, [ref])
        inspector.setIntakeImages(id: event.id, [], now: start)
        XCTAssertEqual(store.calendarEvents.first { $0.id == event.id }?.agenticIntake?.images, [])
    }

    /// On a series occurrence, images customize that one day (the phone's
    /// editOccurrence); the series keeps none.
    func testSeriesImagesCustomizeOneOccurrence() async throws {
        var series = plainEvent()
        series.repeatUnit = .week
        let (store, inspector) = await makeRig(series)
        inspector.select(series.id, occurrenceDate: start.addingTimeInterval(7 * 86_400))
        let ref = AgenticIntakeImageRef(relativePath: "x/y.jpg", pixelWidth: 1, pixelHeight: 1, fileSizeBytes: 1)
        inspector.setIntakeImages(id: series.id, [ref], now: start)
        XCTAssertNil(store.calendarEvents.first { $0.id == series.id }?.agenticIntake)
        let instance = try XCTUnwrap(store.calendarEvents.first { $0.recurrenceParentId == series.id })
        XCTAssertEqual(instance.agenticIntake?.images, [ref])
    }

    // MARK: - Block context menu (the phone's long-press menu)

    func testContextMenuIntentsOpenTheRightPage() async throws {
        let a = plainEvent()
        var b = plainEvent()
        b.timeRanges = [.init(start: start.addingTimeInterval(7200), end: start.addingTimeInterval(10_800))]
        let (store, inspector) = await makeRig(a)
        store.addCalendarEvent(b, now: start)

        inspector.open(a.id, occurrenceDate: start, intent: .log, now: start)
        XCTAssertEqual(inspector.selectedID, a.id)
        XCTAssertEqual(inspector.page, .reflection)

        // Selecting another event lands on its overview, as on the phone.
        inspector.select(b.id, occurrenceDate: b.timeRanges[0].start)
        XCTAssertEqual(inspector.page, .overview)

        inspector.open(a.id, occurrenceDate: start, intent: .addNote, now: start)
        XCTAssertEqual(inspector.page, .overview)
        let occurrence = try XCTUnwrap(inspector.occurrence)
        XCTAssertTrue(inspector.timeline(for: occurrence).isComposing, "the note composer is open")

        inspector.open(a.id, occurrenceDate: start, intent: .details, now: start)
        XCTAssertEqual(inspector.page, .overview)
        XCTAssertTrue(inspector.timeline(for: occurrence).isComposing, "re-opening keeps the open draft")
    }
}

/// The overview's duration stepper and All-day switch.
@MainActor
final class MacOverviewEditTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_773_133_200)   // 2026-03-10 09:00 UTC
    private var utc: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }

    private func rig(minutes: Double, repeating: Bool = false) async -> (MacEventStore, EventInspectorModel, Event) {
        let store = MacTestStore.make(calendar: utc)
        await store.load()
        var e = Event(id: UUID(), title: "E",
                      timeRanges: [.init(start: start, end: start.addingTimeInterval(minutes * 60))], kind: .event)
        if repeating { e.repeatUnit = .day }
        store.addCalendarEvent(e, now: start)
        return (store, EventInspectorModel(store: store, calendar: utc), e)
    }

    func testDurationStepsByFifteenAndFloorsAtFifteen() async {
        let (store, inspector, e) = await rig(minutes: 30)
        inspector.select(e.id)
        inspector.adjustDuration(id: e.id, byMinutes: 15, now: start)
        XCTAssertEqual(store.calendarEvents[0].timeRanges[0].end, start.addingTimeInterval(45 * 60))
        inspector.adjustDuration(id: e.id, byMinutes: -15, now: start)
        inspector.adjustDuration(id: e.id, byMinutes: -15, now: start)
        inspector.adjustDuration(id: e.id, byMinutes: -15, now: start)
        XCTAssertEqual(store.calendarEvents[0].timeRanges[0].end, start.addingTimeInterval(15 * 60), "floors at 15m")
        XCTAssertEqual(store.calendarEvents[0].timeRanges[0].start, start, "the start never moves")
    }

    /// On a series day the step customizes that day only.
    func testDurationStepOnSeriesDayCustomizesThatDay() async throws {
        let (store, inspector, e) = await rig(minutes: 60, repeating: true)
        let day3 = start.addingTimeInterval(2 * 86_400)
        inspector.select(e.id, occurrenceDate: day3)
        inspector.adjustDuration(id: e.id, byMinutes: 15, now: start)
        let template = try XCTUnwrap(store.calendarEvents.first { $0.id == e.id })
        XCTAssertEqual(template.timeRanges[0].end, start.addingTimeInterval(3600), "the series is untouched")
        let instance = try XCTUnwrap(store.calendarEvents.first { $0.recurrenceParentId == e.id })
        XCTAssertEqual(instance.timeRanges[0], .init(start: day3, end: day3.addingTimeInterval(75 * 60)))
    }

    func testAllDaySnapsToWholeDaysAndBack() async throws {
        let (store, inspector, e) = await rig(minutes: 90)
        inspector.select(e.id)
        inspector.setAllDay(id: e.id, true, now: start)
        let on = try XCTUnwrap(store.calendarEvents.first)
        XCTAssertTrue(on.isAllDay)
        let midnight = utc.startOfDay(for: start)
        XCTAssertEqual(on.timeRanges[0].start, midnight)
        XCTAssertEqual(on.timeRanges[0].end, Event.endOfDay(for: start, calendar: utc))
        inspector.setAllDay(id: e.id, false, now: start)
        let off = try XCTUnwrap(store.calendarEvents.first)
        XCTAssertFalse(off.isAllDay)
        XCTAssertEqual(off.timeRanges[0], on.timeRanges[0], "off keeps the stored range, as the phone form does")
    }
}

/// "With": the event's people, on the shared roster.
@MainActor
final class MacPeopleTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_773_133_200)

    func testPeopleToggleGroupAndNewPerson() async throws {
        let store = MacTestStore.make()
        await store.load()
        let e = Event(id: UUID(), title: "Dinner",
                      timeRanges: [.init(start: start, end: start.addingTimeInterval(3600))], kind: .event)
        store.addCalendarEvent(e, now: start)
        let ann = try XCTUnwrap(store.shared.addPerson(named: "Ann"))
        let bo = try XCTUnwrap(store.shared.addPerson(named: "Bo"))
        var gone = Person(name: "Gone"); gone.isArchived = true
        store.shared.addPerson(gone)
        store.shared.friendGroups = [FriendGroup(name: "Fam", memberIDs: [bo.id, gone.id])]
        let inspector = EventInspectorModel(store: store, calendar: .current)
        inspector.select(e.id)
        func ids() -> [UUID]? { store.calendarEvents.first { $0.id == e.id }?.peopleIDs }

        inspector.togglePerson(id: e.id, ann.id, now: start)
        XCTAssertEqual(ids(), [ann.id])
        inspector.addGroup(id: e.id, store.shared.friendGroups[0], now: start)
        XCTAssertEqual(ids(), [ann.id, bo.id], "current, active members only; no duplicates")
        inspector.addNewPerson(id: e.id, named: " ann ", now: start)
        XCTAssertEqual(ids(), [ann.id, bo.id], "an existing name is reused, not duplicated")
        inspector.addNewPerson(id: e.id, named: "Cy", now: start)
        XCTAssertEqual(inspector.people(for: try XCTUnwrap(store.calendarEvents.first)).map(\.name), ["Ann", "Bo", "Cy"])
        inspector.togglePerson(id: e.id, ann.id, now: start)
        inspector.togglePerson(id: e.id, bo.id, now: start)
        inspector.togglePerson(id: e.id, store.shared.activePeople.first { $0.name == "Cy" }!.id, now: start)
        XCTAssertNil(ids(), "empty stores nil, as the phone form does")
    }
}

/// Share: the phone's card, built from the same inputs, renders on the Mac.
@MainActor
final class MacShareTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_773_133_200)

    func testShareCardCarriesNotesAndRenders() async throws {
        let store = MacTestStore.make()
        await store.load()
        let e = Event(id: UUID(), title: "Run",
                      timeRanges: [.init(start: start, end: start.addingTimeInterval(3600))], kind: .event)
        store.addCalendarEvent(e, now: start)
        let inspector = EventInspectorModel(store: store, calendar: .current)
        inspector.open(e.id, occurrenceDate: start, intent: .share, now: start)
        XCTAssertTrue(inspector.isSharing)
        let occurrence = try XCTUnwrap(inspector.occurrence)
        store.shared.appendTimelineNote("5k done", createdAt: start.addingTimeInterval(1800),
                                        source: "test", for: occurrence)
        let card = InspectorShareSheet.card(event: e, range: try XCTUnwrap(inspector.occurrenceRange),
                                            occurrence: occurrence, store: store.shared)
        XCTAssertEqual(card.notes.map(\.text), ["5k done"])
        let image = try XCTUnwrap(InspectorShareSheet.render(card))
        XCTAssertEqual(image.size.width, CalendarEventShareCard.cardWidth, accuracy: 1)
        XCTAssertNotNil(ShareImage.png(image))
    }

    /// A todo with no time has nothing to share (no slider).
    func testUnscheduledTodoCannotOpenShare() async throws {
        let store = MacTestStore.make()
        await store.load()
        let todo = Event(id: UUID(), title: "Buy milk", timeRanges: [], kind: .todo)
        store.addCalendarEvent(todo, now: start)
        let inspector = EventInspectorModel(store: store, calendar: .current)
        inspector.open(todo.id, occurrenceDate: nil, intent: .share, now: start)
        XCTAssertFalse(inspector.isSharing)
    }
}

/// Absorbed todos: the phone's absorb / release on the shared store.
@MainActor
final class MacAbsorbTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_773_133_200)

    func testAbsorbListsAndReleases() async throws {
        let store = MacTestStore.make()
        await store.load()
        let parent = Event(id: UUID(), title: "Errands",
                           timeRanges: [.init(start: start, end: start.addingTimeInterval(3600))], kind: .event)
        let milk = Event(id: UUID(), title: "Buy milk", timeRanges: [], kind: .todo)
        let mail = Event(id: UUID(), title: "Post letter", timeRanges: [], kind: .todo)
        for e in [parent, milk, mail] { store.addCalendarEvent(e, now: start) }
        let inspector = EventInspectorModel(store: store, calendar: .current)

        XCTAssertEqual(Set(inspector.absorbCandidates(matching: "").map(\.id)), [milk.id, mail.id],
                       "only todos are candidates")
        XCTAssertEqual(inspector.absorbCandidates(matching: " MILK ").map(\.id), [milk.id])
        // Absorbed before the parent ends: stays open.
        inspector.absorb(todoID: milk.id, into: parent.id, now: start)
        XCTAssertEqual(inspector.absorbedTodos(of: parent.id).map(\.id), [milk.id])
        XCTAssertFalse(inspector.absorbCandidates(matching: "").contains { $0.id == milk.id })
        XCTAssertEqual(inspector.absorbedTodos(of: parent.id).first?.isDone, false)

        inspector.releaseAbsorption(todoID: milk.id)
        XCTAssertTrue(inspector.absorbedTodos(of: parent.id).isEmpty)
        XCTAssertTrue(inspector.absorbCandidates(matching: "").contains { $0.id == milk.id })
    }
}
