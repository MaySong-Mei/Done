//
//  MacTimelineNotesTests.swift
//  DoneMacTests
//
//  The inspector's timeline + note log writes the occurrence's log record
//  the phone reads: notes land at the track's instant (live = now, manual =
//  the scrubbed time), edits keep their time, a pane torn down mid-draft
//  keeps what was typed (once), and scrubbing uses the phone's snap/live
//  rules. Expected values are hand-computed.
//

import XCTest
@testable import Done

@MainActor
final class MacTimelineNotesTests: XCTestCase {
    // 2026-03-10 09:00–10:00 UTC event.
    private let start = Date(timeIntervalSince1970: 1_773_133_200)
    private var range: Event.TimeRange { .init(start: start, end: start.addingTimeInterval(3600)) }
    private var imageDir: URL!

    override func setUp() async throws {
        imageDir = FileManager.default.temporaryDirectory.appendingPathComponent("mac-tl-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: imageDir)
    }

    private func makeTimeline() async -> (InspectorTimelineModel, EventStore, CalendarEventOccurrenceContext) {
        let store = MacTestStore.make()
        await store.load()
        let event = Event(id: UUID(), title: "Deep work", timeRanges: [range], kind: .event)
        store.addCalendarEvent(event, now: start)
        let occurrence = CalendarEventOccurrenceContext(eventID: event.id, occurrenceDate: start, occurrenceID: nil,
                                                        isAllDay: false, source: .timelineTap)
        let assets = AgenticIntakeAssetStore(baseDirectoryURL: imageDir, ownsDirectory: false)
        return (InspectorTimelineModel(occurrence: occurrence, store: store.shared, assets: assets),
                store.shared, occurrence)
    }

    /// The note list the phone's detail builds from the same record.
    private func phoneNotes(_ store: EventStore, _ occurrence: CalendarEventOccurrenceContext) -> [EventLogTimelineNote] {
        store.prefilledDraft(for: occurrence).timelineNotes
    }

    func testLiveNoteLandsAtNowAndThePhoneSeesIt() async {
        let (timeline, store, occurrence) = await makeTimeline()
        let now = start.addingTimeInterval(20 * 60)
        timeline.beginAdding(now: now)
        timeline.draftText = "  outlined the doc  "
        timeline.save(now: now, range: range)
        XCTAssertFalse(timeline.isComposing)
        let notes = phoneNotes(store, occurrence)
        XCTAssertEqual(notes.map(\.text), ["outlined the doc"])
        XCTAssertEqual(notes.first?.createdAt, now)
        XCTAssertEqual(timeline.notes.map(\.text), ["outlined the doc"])
    }

    /// Scrubbed to 75% of a 60-minute event: the note lands at 9:45.
    func testManualScrubPlacesTheNote() async {
        let (timeline, store, occurrence) = await makeTimeline()
        let now = start.addingTimeInterval(10 * 60)
        timeline.scrub(to: 0.75, now: now, range: range)
        XCTAssertEqual(timeline.mode, .manual)
        timeline.beginAdding(now: now)
        timeline.draftText = "later"
        timeline.save(now: now, range: range)
        XCTAssertEqual(phoneNotes(store, occurrence).first?.createdAt, start.addingTimeInterval(45 * 60))
    }

    /// Scrubbing within two minutes of a note snaps onto it; landing on
    /// "now" goes back to live.
    func testScrubSnapsToNoteAndResumesLiveAtNow() async {
        let (timeline, _, _) = await makeTimeline()
        let now = start.addingTimeInterval(30 * 60)
        timeline.beginAdding(now: now)
        timeline.draftText = "n"
        timeline.scrub(to: 0.2, now: now, range: range)   // 9:12, manual
        timeline.save(now: now, range: range)
        // 9:13 is one minute from the note at 9:12 → snaps to 0.2.
        timeline.scrub(to: 13.0 / 60.0, now: now, range: range)
        XCTAssertEqual(timeline.mode, .manual)
        XCTAssertEqual(timeline.resolvedState(now: now, range: range).displayProgress, 0.2, accuracy: 1e-6)
        // 9:30 is now → live.
        timeline.scrub(to: 0.5, now: now, range: range)
        XCTAssertEqual(timeline.mode, .live)
    }

    func testIdleManualTrackResumesLiveAfterThirtySeconds() async {
        let (timeline, _, _) = await makeTimeline()
        let now = start.addingTimeInterval(5 * 60)
        timeline.scrub(to: 0.9, now: now, range: range)
        timeline.tick(now: now.addingTimeInterval(29))
        XCTAssertEqual(timeline.mode, .manual)
        timeline.tick(now: now.addingTimeInterval(30))
        XCTAssertEqual(timeline.mode, .live)
    }

    func testEditKeepsTheNoteTimeAndDeleteRemovesIt() async {
        let (timeline, store, occurrence) = await makeTimeline()
        let now = start.addingTimeInterval(15 * 60)
        timeline.beginAdding(now: now)
        timeline.draftText = "first"
        timeline.save(now: now, range: range)
        let note = timeline.notes[0]

        timeline.beginEditing(note, now: now.addingTimeInterval(600))
        XCTAssertEqual(timeline.draftText, "first")
        timeline.draftText = "first, edited"
        timeline.save(now: now.addingTimeInterval(600), range: range)
        XCTAssertEqual(phoneNotes(store, occurrence).map(\.text), ["first, edited"])
        XCTAssertEqual(phoneNotes(store, occurrence).first?.createdAt, now)

        timeline.delete(timeline.notes[0])
        XCTAssertTrue(phoneNotes(store, occurrence).isEmpty)
    }

    func testEmptyDraftDoesNotSave() async {
        let (timeline, store, occurrence) = await makeTimeline()
        timeline.beginAdding(now: start)
        timeline.draftText = "   "
        XCTAssertFalse(timeline.canSave)
        timeline.save(now: start, range: range)
        XCTAssertTrue(phoneNotes(store, occurrence).isEmpty)
        XCTAssertTrue(timeline.isComposing, "nothing saved, the composer stays open")
    }

    /// The pane going away with a draft keeps it — once: a second flush
    /// updates the same note instead of appending another.
    func testFlushKeepsTheDraftOnce() async {
        let (timeline, store, occurrence) = await makeTimeline()
        let now = start.addingTimeInterval(40 * 60)
        timeline.beginAdding(now: now)
        timeline.draftText = "half a thought"
        timeline.flush(now: now, range: range)
        timeline.draftText = "half a thought, finished"
        timeline.flush(now: now, range: range)
        XCTAssertEqual(phoneNotes(store, occurrence).map(\.text), ["half a thought, finished"])
    }

    /// Flushing while EDITING an existing note never commits the half-edit.
    func testFlushNeverCommitsAHalfEdit() async {
        let (timeline, store, occurrence) = await makeTimeline()
        timeline.beginAdding(now: start)
        timeline.draftText = "kept"
        timeline.save(now: start, range: range)
        timeline.beginEditing(timeline.notes[0], now: start)
        timeline.draftText = "half-ed"
        timeline.flush(now: start, range: range)
        XCTAssertEqual(phoneNotes(store, occurrence).map(\.text), ["kept"])
    }

    /// flush → reopen THAT flushed note for editing → flush: the second
    /// flush must not write the half-edit (beginEditing drops the
    /// flush-created id, so the note is now "an existing note").
    func testFlushThenEditTheFlushedNoteNeverCommitsTheHalfEdit() async {
        let (timeline, store, occurrence) = await makeTimeline()
        timeline.beginAdding(now: start)
        timeline.draftText = "flushed"
        timeline.flush(now: start.addingTimeInterval(60), range: range)
        let flushed = timeline.notes[0]
        timeline.beginEditing(flushed, now: start)
        timeline.draftText = "flushed, half-ed"
        timeline.flush(now: start, range: range)
        XCTAssertEqual(phoneNotes(store, occurrence).map(\.text), ["flushed"])
    }

    /// Images picked before a flush are imported once; a later save does not
    /// import them again.
    func testFlushedImagesAreNotImportedTwice() async {
        let (timeline, store, occurrence) = await makeTimeline()
        timeline.beginAdding(now: start)
        timeline.draftText = "pic"
        timeline.addImage(data: Self.png)
        timeline.flush(now: start, range: range)
        timeline.save(now: start, range: range)
        XCTAssertEqual(phoneNotes(store, occurrence).first?.images.count, 1)
        let files = (try? FileManager.default.subpathsOfDirectory(atPath: imageDir.path)) ?? []
        XCTAssertEqual(files.filter { $0.hasSuffix(".jpg") || $0.hasSuffix(".png") }.count, 1)
    }

    private static let png = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!

    func testImagesAreImportedOnceAndCapped() async {
        let (timeline, store, occurrence) = await makeTimeline()
        timeline.beginAdding(now: start)
        let png = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
        for _ in 0..<7 { timeline.addImage(data: png) }
        XCTAssertEqual(timeline.imageCount, InspectorTimelineModel.maxImages)
        timeline.save(now: start, range: range)
        let images = phoneNotes(store, occurrence).first?.images ?? []
        XCTAssertEqual(images.count, 5)
        XCTAssertTrue(FileManager.default.fileExists(atPath: timeline.imageURL(images[0]).path))
    }
}

/// The occurrence the inspector keys notes and effort by must be the one the
/// phone's detail route uses — for a series, the series id + the clicked day.
@MainActor
final class MacInspectorOccurrenceKeyTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_773_133_200)   // 2026-03-10 09:00 UTC

    func testSeriesDayNotesAndEffortKeyToThatDay() async throws {
        let store = MacTestStore.make()
        await store.load()
        var series = Event(id: UUID(), title: "Standup",
                           timeRanges: [.init(start: start, end: start.addingTimeInterval(1800))], kind: .event)
        series.repeatUnit = .day
        store.addCalendarEvent(series, now: start)
        let inspector = EventInspectorModel(store: store, calendar: .current)
        let laterDay = start.addingTimeInterval(7 * 86_400)
        inspector.select(series.id, occurrenceDate: laterDay)

        let occurrence = try XCTUnwrap(inspector.occurrence)
        let timeline = inspector.timeline(for: occurrence)
        timeline.beginAdding(now: laterDay)
        timeline.draftText = "day 8"
        timeline.save(now: laterDay, range: inspector.occurrenceRange)
        inspector.setEffort(id: series.id, 2, now: laterDay)

        // The phone's route for that block: series id + that occurrence's start.
        let phoneRoute = CalendarEventOccurrenceContext(eventID: series.id, occurrenceDate: laterDay,
                                                        occurrenceID: nil, isAllDay: false, source: .timelineTap)
        XCTAssertEqual(store.shared.prefilledDraft(for: phoneRoute).timelineNotes.map(\.text), ["day 8"])
        XCTAssertEqual(store.shared.prefilledDraft(for: phoneRoute).effort, 2)
        // The series' first day keeps its own (empty) record.
        let firstDay = CalendarEventOccurrenceContext(eventID: series.id, occurrenceDate: start,
                                                      occurrenceID: nil, isAllDay: false, source: .timelineTap)
        XCTAssertNil(store.shared.logRecord(for: firstDay))
    }

    /// Quitting with a note half-typed keeps it (the runtime's draft flush).
    func testQuitFlushKeepsTheOpenDraft() async throws {
        let store = MacTestStore.make()
        await store.load()
        let event = Event(id: UUID(), title: "Write",
                          timeRanges: [.init(start: start, end: start.addingTimeInterval(3600))], kind: .event)
        store.addCalendarEvent(event, now: start)
        let inspector = EventInspectorModel(store: store, calendar: .current)
        inspector.open(event.id, occurrenceDate: start, intent: .addNote, now: start)
        let occurrence = try XCTUnwrap(inspector.occurrence)
        inspector.timeline(for: occurrence).draftText = "unsaved thought"
        inspector.flushDrafts(now: start.addingTimeInterval(600))
        XCTAssertEqual(store.shared.prefilledDraft(for: occurrence).timelineNotes.map(\.text), ["unsaved thought"])
    }
}
