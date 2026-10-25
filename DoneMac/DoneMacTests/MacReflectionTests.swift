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
