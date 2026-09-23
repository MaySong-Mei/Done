//
//  EventStoreDeletionOrderingTests.swift
//  DoneTests
//
//  Issue #145 A + B: one user operation, one order.
//
//  These tests do not assert what a delete produces — other suites already do
//  that. They assert the ORDER it produces it in, because the order is what
//  decides which half of a killed operation the user is left holding:
//
//  - the authoritative calendar state commits FIRST, so a kill can never leave
//    a surviving event whose records or photos are already destroyed;
//  - image files are unlinked LAST, and only when every slot the operation had
//    to write reported a durable commit;
//  - a REFUSED or FAILED calendar commit destroys nothing at all — not the
//    photos, not the log/feedback rows, not the `.following` reindex — because
//    the event it belongs to is still on disk and comes back on the next
//    launch;
//  - a "this and following" split lands in exactly ONE calendar commit, so a
//    kill cannot leave both the old and the new series alive on the same days.
//
//  - and the launch sweep that cleans up after a killed delete refuses to run
//    on anything less than a provably complete reference set.
//
//  The trace is built from two seams on `EventStore`: `onSlotCommitted` fires
//  per slot that actually reached disk, `removeAssetFiles` stands in for the
//  unlink. The shared asset directory is never touched — it is not redirected
//  under XCTest and a test must never write into it; the sweep tests at the
//  bottom write into a throwaway directory and point the collector at it.
//

import XCTest
@testable import Done

@MainActor
final class EventStoreDeletionOrderingTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var location: EventStorageLocation!
    private var assetDirectory: URL!
    private var trace: [String] = []

    override func setUp() {
        super.setUp()
        suiteName = "EventStoreDeletionOrderingTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        location = TestStorage.reset(suiteName)
        assetDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeletionOrderingAssets-\(UUID().uuidString)", isDirectory: true)
        trace = []
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: assetDirectory)
        TestStorage.tearDown(suiteName)
        defaults = nil
        suiteName = nil
        location = nil
        assetDirectory = nil
        trace = []
        super.tearDown()
    }

    // MARK: - Fixtures

    private func makeStore() -> EventStore {
        EventStore(defaults: defaults, storage: location, seedsSampleDataIfEmpty: false)
    }

    /// Attach the trace AFTER the fixture is built, so only the operation
    /// under test shows up in it.
    private func instrument(_ store: EventStore) {
        store.onSlotCommitted = { [weak self] slot in
            self?.trace.append("commit:\(slot.rawValue)")
        }
        store.removeAssetFiles = { [weak self] refs in
            self?.trace.append("unlink:" + refs.map(\.relativePath).sorted().joined(separator: ","))
        }
    }

    private func imageRef(_ path: String) -> AgenticIntakeImageRef {
        AgenticIntakeImageRef(relativePath: path, pixelWidth: 1, pixelHeight: 1, fileSizeBytes: 1)
    }

    private func photoEvent(_ title: String, id: UUID = UUID(), daysFromNow: Int = 0) -> Event {
        let start = Calendar.current.date(byAdding: .day, value: daysFromNow, to: Date())!
        var event = Event(
            id: id,
            title: title,
            timeRanges: [.init(start: start, end: start.addingTimeInterval(3600))],
            type: "Study"
        )
        event.agenticIntake = AgenticIntakeRecord(
            rawText: "",
            images: [imageRef("\(id.uuidString)/photo.jpg")],
            source: .classicFallback
        )
        return event
    }

    private func occurrence(_ eventID: UUID, on date: Date) -> CalendarEventOccurrenceContext {
        CalendarEventOccurrenceContext(
            eventID: eventID,
            occurrenceDate: date,
            occurrenceID: nil,
            isAllDay: false,
            source: .timelineTap
        )
    }

    // MARK: - Fault injection

    /// A REAL write failure in the calendar slot, with nothing corrupt and no
    /// slot frozen: the primary path is replaced by a NON-EMPTY DIRECTORY, so
    /// the commit's `rename(2)` fails with `ENOTEMPTY`. This is the disk-full /
    /// unwritable-container case the audit's acceptance list calls "write
    /// failure in each affected slot", and it is the one the freeze path
    /// cannot model: reads keep working, every other slot commits normally.
    ///
    /// Returns the bytes it displaced so the caller can put the file back and
    /// "relaunch" with a fresh store over the same directory.
    private func breakCalendarWrites() throws -> Data {
        let primary = try location.directoryURL()
            .appendingPathComponent(StorageSlot.calendarEvents.filename)
        let good = try Data(contentsOf: primary)
        let fileManager = FileManager.default
        try fileManager.removeItem(at: primary)
        try fileManager.createDirectory(at: primary, withIntermediateDirectories: false)
        try Data("occupied".utf8).write(to: primary.appendingPathComponent("occupied"))
        return good
    }

    private func repairCalendarWrites(restoring good: Data) throws {
        let primary = try location.directoryURL()
            .appendingPathComponent(StorageSlot.calendarEvents.filename)
        try FileManager.default.removeItem(at: primary)
        try good.write(to: primary)
    }

    private var unlinkIndex: Int? {
        trace.firstIndex { $0.hasPrefix("unlink:") }
    }

    private func index(ofCommit slot: StorageSlot) -> Int? {
        trace.firstIndex(of: "commit:\(slot.rawValue)")
    }

    // MARK: - Single event

    /// The reported worst case: the photo file was unlinked before the event
    /// row was committed, so a kill in between left a surviving event pointing
    /// at a photo that no longer existed — and unlike the event, a photo has
    /// no legacy or cloud fallback.
    func testDeletingAnEventCommitsTheCalendarBeforeUnlinkingItsPhotos() {
        let store = makeStore()
        let event = photoEvent("Lunch")
        store.addCalendarEvent(event)
        store.upsertLogRecord(for: occurrence(event.id, on: Date())) { $0.note = "how it went" }
        instrument(store)

        store.deleteCalendarEvent(store.findCalendarEvent(id: event.id)!)

        XCTAssertEqual(trace.first, "commit:\(StorageSlot.calendarEvents.rawValue)",
                       "the authoritative state must be the first thing committed")
        let unlink = try? XCTUnwrap(unlinkIndex)
        XCTAssertNotNil(unlink, "the orphaned photo should still be deleted eventually")
        XCTAssertEqual(unlink, trace.count - 1, "unlinking files is the LAST step")
        XCTAssertEqual(trace.last, "unlink:\(event.id.uuidString)/photo.jpg")
        XCTAssertFalse(store.rawCalendarEvents.contains { $0.id == event.id })
    }

    /// The other half of #145 B: records used to be pruned (and committed)
    /// while the event that owned them was still durable on disk.
    func testDeletingAnEventCommitsTheCalendarBeforePruningItsRecords() {
        let store = makeStore()
        let event = photoEvent("Gym")
        store.addCalendarEvent(event)
        store.upsertLogRecord(for: occurrence(event.id, on: Date())) { $0.note = "notes" }
        store.upsertFeedbackRecord(for: occurrence(event.id, on: Date())) { $0.selfNote = "felt fine" }
        instrument(store)

        store.deleteCalendarEvent(store.findCalendarEvent(id: event.id)!)

        let calendar = try? XCTUnwrap(index(ofCommit: .calendarEvents))
        let logs = try? XCTUnwrap(index(ofCommit: .calendarEventLogRecords))
        let feedback = try? XCTUnwrap(index(ofCommit: .calendarEventFeedbackRecords))
        XCTAssertNotNil(logs)
        XCTAssertNotNil(feedback)
        XCTAssertLessThan(calendar ?? .max, logs ?? -1)
        XCTAssertLessThan(calendar ?? .max, feedback ?? -1)
        XCTAssertTrue(store.calendarEventLogRecords.isEmpty)
        XCTAssertTrue(store.calendarEventFeedbackRecords.isEmpty)
    }

    /// "Commit the record cleanup" has to mean the cleanup is ON DISK.
    ///
    /// It was not: the prune helpers took the store's `@Published` array
    /// `inout` and saved from inside, so the save re-encoded the pre-prune
    /// array, the storage layer skipped the byte-identical payload, and the
    /// deleted event's records came back on the next launch.
    func testPrunedRecordsAreVisibleToAFreshStore() {
        let store = makeStore()
        let event = photoEvent("Dentist")
        store.addCalendarEvent(event)
        store.upsertLogRecord(for: occurrence(event.id, on: Date())) { $0.note = "note" }
        store.upsertFeedbackRecord(for: occurrence(event.id, on: Date())) { $0.selfNote = "felt fine" }

        store.deleteCalendarEvent(store.findCalendarEvent(id: event.id)!)

        let reloaded = makeStore()
        XCTAssertTrue(reloaded.calendarEventLogRecords.isEmpty,
                      "the log prune must survive the process, not just the session")
        XCTAssertTrue(reloaded.calendarEventFeedbackRecords.isEmpty)
        XCTAssertTrue(reloaded.rawCalendarEvents.isEmpty)
    }

    /// The chosen failure direction, expressed as a test: when the calendar
    /// commit is REFUSED (frozen slot), the event is still on disk — so its
    /// photos must stay on disk with it. An orphan record is recoverable; an
    /// erased photo is not.
    func testARefusedCalendarCommitKeepsTheImageFiles() throws {
        let first = makeStore()
        first.addCalendarEvent(photoEvent("Anchor"))

        // Corrupt both copies so the next launch freezes the calendar slot.
        let primary = try location.directoryURL()
            .appendingPathComponent(StorageSlot.calendarEvents.filename)
        try Data("shredded".utf8).write(to: primary)
        try? FileManager.default.removeItem(
            at: try location.directoryURL()
                .appendingPathComponent(StorageSlot.calendarEvents.backupFilename))

        let frozen = makeStore()
        XCTAssertTrue(frozen.isSlotFrozen(.calendarEvents))
        // In memory only — the append lands, the commit is refused.
        let event = photoEvent("Doomed")
        frozen.addCalendarEvent(event)
        instrument(frozen)

        frozen.deleteCalendarEvent(event)

        XCTAssertNil(unlinkIndex, "a delete that could not be committed must not destroy photos")
        XCTAssertNil(index(ofCommit: .calendarEvents))
    }

    // MARK: - A refused calendar commit must not destroy the records

    /// The same failure direction as the photo, for the metadata: the calendar
    /// slot is frozen by a TRANSIENT read fault (a locked container at launch —
    /// the bytes on disk were never bad), so the event is still there and comes
    /// back on the next launch. Its log and feedback rows must come back with
    /// it; the record slots are perfectly writable, which is exactly why an
    /// ungated prune would destroy them for good.
    func testARefusedCalendarCommitKeepsTheEventsRecords() throws {
        let first = makeStore()
        let event = photoEvent("Therapy")
        first.addCalendarEvent(event)
        first.upsertLogRecord(for: occurrence(event.id, on: Date())) { $0.note = "what we covered" }
        first.upsertFeedbackRecord(for: occurrence(event.id, on: Date())) { $0.selfNote = "felt heard" }

        let primary = try location.directoryURL()
            .appendingPathComponent(StorageSlot.calendarEvents.filename)
        let goodBytes = try Data(contentsOf: primary)
        try Data("shredded".utf8).write(to: primary)
        try? FileManager.default.removeItem(
            at: try location.directoryURL()
                .appendingPathComponent(StorageSlot.calendarEvents.backupFilename))

        let frozen = makeStore()
        XCTAssertTrue(frozen.isSlotFrozen(.calendarEvents))
        XCTAssertEqual(frozen.calendarEventLogRecords.count, 1, "only the calendar slot faulted")
        XCTAssertEqual(frozen.calendarEventFeedbackRecords.count, 1)
        instrument(frozen)

        frozen.deleteCalendarEvent(event)

        XCTAssertNil(index(ofCommit: .calendarEventLogRecords),
                     "no record slot may be committed behind a refused calendar commit")
        XCTAssertNil(index(ofCommit: .calendarEventFeedbackRecords))

        // The fault was transient: the original bytes go back, the app relaunches.
        try goodBytes.write(to: primary)
        let reloaded = makeStore()
        XCTAssertTrue(reloaded.rawCalendarEvents.contains { $0.id == event.id },
                      "a refused commit leaves the event on disk")
        XCTAssertEqual(reloaded.calendarEventLogRecords.count, 1,
                       "a surviving event must not lose its log records")
        XCTAssertEqual(reloaded.calendarEventFeedbackRecords.count, 1,
                       "a surviving event must not lose its feedback records")
    }

    /// The same invariant reached without freezing anything and without a
    /// single corrupt byte: a REAL I/O failure in the calendar slot only.
    func testAFailedCalendarWriteKeepsTheEventsRecords() throws {
        let store = makeStore()
        let event = photoEvent("Dentist")
        store.addCalendarEvent(event)
        store.upsertLogRecord(for: occurrence(event.id, on: Date())) { $0.note = "drilling" }
        store.upsertFeedbackRecord(for: occurrence(event.id, on: Date())) { $0.selfNote = "ow" }
        let goodBytes = try breakCalendarWrites()
        instrument(store)

        store.deleteCalendarEvent(store.findCalendarEvent(id: event.id)!)

        XCTAssertTrue(store.writeFailedSlots.contains(.calendarEvents),
                      "the probe must actually fail the calendar write")
        XCTAssertNil(index(ofCommit: .calendarEventLogRecords))
        XCTAssertNil(index(ofCommit: .calendarEventFeedbackRecords))
        XCTAssertNil(unlinkIndex)

        try repairCalendarWrites(restoring: goodBytes)
        let reloaded = makeStore()
        XCTAssertTrue(reloaded.rawCalendarEvents.contains { $0.id == event.id })
        XCTAssertEqual(reloaded.calendarEventLogRecords.count, 1,
                       "a surviving event must not lose its log records")
        XCTAssertEqual(reloaded.calendarEventFeedbackRecords.count, 1,
                       "a surviving event must not lose its feedback records")
    }

    /// The recurring path has the identical shape, so it needs the identical
    /// gate: a failed calendar write leaves the whole series on disk, and the
    /// series' logged history must not be pruned out from under it.
    func testAFailedCalendarWriteKeepsARecurringSeriesRecords() throws {
        let store = makeStore()
        let seriesID = UUID()
        var series = photoEvent("Daily", id: seriesID)
        series.repeatUnit = .day
        series.repeatInterval = 1
        store.addCalendarEvent(series)
        store.upsertLogRecord(for: occurrence(seriesID, on: Date())) { $0.note = "day note" }
        store.upsertFeedbackRecord(for: occurrence(seriesID, on: Date())) { $0.selfNote = "fine" }
        let goodBytes = try breakCalendarWrites()
        instrument(store)

        store.deleteRecurringCalendarEvent(
            seriesEvent: store.findCalendarEvent(id: seriesID)!,
            occurrenceDate: Date(),
            scope: .all
        )

        XCTAssertTrue(store.writeFailedSlots.contains(.calendarEvents))
        XCTAssertNil(index(ofCommit: .calendarEventLogRecords))
        XCTAssertNil(index(ofCommit: .calendarEventFeedbackRecords))

        try repairCalendarWrites(restoring: goodBytes)
        let reloaded = makeStore()
        XCTAssertTrue(reloaded.rawCalendarEvents.contains { $0.id == seriesID })
        XCTAssertEqual(reloaded.calendarEventLogRecords.count, 1,
                       "a surviving series must not lose its log records")
        XCTAssertEqual(reloaded.calendarEventFeedbackRecords.count, 1,
                       "a surviving series must not lose its feedback records")
    }

    /// The edit side of the same hole. A `.following` split whose one calendar
    /// commit failed did not create the new series on disk — but the reindex
    /// ran anyway and durably re-pointed the logged history at its id, so the
    /// notes were reachable from no series that exists while the old one came
    /// back uncapped.
    func testAFailedFollowingSplitDoesNotReanchorTheRecords() throws {
        let store = makeStore()
        let calendar = Calendar.current
        let day0 = calendar.startOfDay(for: Date())
        func day(_ n: Int) -> Date { calendar.date(byAdding: .day, value: n, to: day0)! }

        let seriesID = UUID()
        var series = Event(
            id: seriesID,
            title: "Daily",
            timeRanges: [.init(start: day0.addingTimeInterval(9 * 3600),
                               end: day0.addingTimeInterval(10 * 3600))],
            type: "Study"
        )
        series.repeatUnit = .day
        series.repeatInterval = 1
        store.addCalendarEvent(series)
        store.upsertLogRecord(for: occurrence(seriesID, on: day(5))) { $0.note = "day5" }
        store.upsertFeedbackRecord(for: occurrence(seriesID, on: day(5))) { $0.selfNote = "day5" }
        let goodBytes = try breakCalendarWrites()
        instrument(store)

        store.applyRecurringEdit(
            seriesEvent: store.findCalendarEvent(id: seriesID)!,
            occurrenceDate: day(3),
            scope: .following
        ) { $0.title = "New" }

        XCTAssertTrue(store.writeFailedSlots.contains(.calendarEvents))
        XCTAssertNil(index(ofCommit: .calendarEventLogRecords),
                     "the reindex must not commit onto a series that never reached disk")
        XCTAssertNil(index(ofCommit: .calendarEventFeedbackRecords))

        try repairCalendarWrites(restoring: goodBytes)
        let reloaded = makeStore()
        XCTAssertEqual(reloaded.rawCalendarEvents.count, 1, "the split never reached disk")
        XCTAssertEqual(reloaded.calendarEventLogRecords.first?.baseSeriesEventID, seriesID,
                       "the log must stay on the series that still exists")
        XCTAssertEqual(reloaded.calendarEventFeedbackRecords.first?.baseSeriesEventID, seriesID,
                       "the feedback must stay on the series that still exists")
    }

    // MARK: - Recurring deletes

    func testDeletingAWholeSeriesCommitsBeforeUnlinking() {
        let store = makeStore()
        let seriesID = UUID()
        var series = photoEvent("Daily", id: seriesID)
        series.repeatUnit = .day
        series.repeatInterval = 1
        store.addCalendarEvent(series)
        store.upsertLogRecord(for: occurrence(seriesID, on: Date())) { $0.note = "day note" }
        instrument(store)

        store.deleteRecurringCalendarEvent(
            seriesEvent: store.findCalendarEvent(id: seriesID)!,
            occurrenceDate: Date(),
            scope: .all
        )

        XCTAssertEqual(trace.first, "commit:\(StorageSlot.calendarEvents.rawValue)")
        XCTAssertEqual(unlinkIndex, trace.count - 1)
        XCTAssertLessThan(index(ofCommit: .calendarEvents) ?? .max,
                          index(ofCommit: .calendarEventLogRecords) ?? -1)
        XCTAssertTrue(store.rawCalendarEvents.isEmpty)
    }

    func testDeletingThisAndFollowingCommitsBeforeUnlinking() {
        let store = makeStore()
        let calendar = Calendar.current
        let day0 = calendar.startOfDay(for: Date())
        func day(_ n: Int) -> Date { calendar.date(byAdding: .day, value: n, to: day0)! }

        let seriesID = UUID()
        var series = Event(
            id: seriesID,
            title: "Daily",
            timeRanges: [.init(start: day0.addingTimeInterval(9 * 3600),
                               end: day0.addingTimeInterval(10 * 3600))],
            type: "Study"
        )
        series.repeatUnit = .day
        series.repeatInterval = 1
        store.addCalendarEvent(series)
        // A materialized exception on day 5, carrying its own photo. The
        // `.following` sweep removes it, so its file orphans.
        store.applyRecurringEdit(
            seriesEvent: store.findCalendarEvent(id: seriesID)!,
            occurrenceDate: day(5),
            scope: .single
        ) { occurrence in
            occurrence.agenticIntake = AgenticIntakeRecord(
                rawText: "",
                images: [self.imageRef("day5/photo.jpg")],
                source: .classicFallback
            )
        }
        instrument(store)

        store.deleteRecurringCalendarEvent(
            seriesEvent: store.findCalendarEvent(id: seriesID)!,
            occurrenceDate: day(3),
            scope: .following
        )

        XCTAssertEqual(trace.first, "commit:\(StorageSlot.calendarEvents.rawValue)")
        XCTAssertEqual(trace.last, "unlink:day5/photo.jpg")
        // Behaviour unchanged: the series is capped and the swept exception is gone.
        let capped = store.findCalendarEvent(id: seriesID)
        XCTAssertEqual(capped?.repeatEndType, .onDate)
        XCTAssertFalse(store.rawCalendarEvents.contains { $0.recurrenceParentId == seriesID })
    }

    // MARK: - The "this and following" split

    /// Four commits became one. With four, a kill after the first left the new
    /// series AND the uncapped old series both alive over the same days — a
    /// state no user action asks for and no later operation repairs.
    func testFollowingEditLandsInExactlyOneCalendarCommit() {
        let store = makeStore()
        let calendar = Calendar.current
        let day0 = calendar.startOfDay(for: Date())
        func day(_ n: Int) -> Date { calendar.date(byAdding: .day, value: n, to: day0)! }

        let seriesID = UUID()
        var series = Event(
            id: seriesID,
            title: "Daily",
            timeRanges: [.init(start: day0.addingTimeInterval(9 * 3600),
                               end: day0.addingTimeInterval(10 * 3600))],
            type: "Study"
        )
        series.repeatUnit = .day
        series.repeatInterval = 1
        store.addCalendarEvent(series)
        store.upsertLogRecord(for: occurrence(seriesID, on: day(5))) { $0.note = "day5" }
        store.upsertFeedbackRecord(for: occurrence(seriesID, on: day(5))) { $0.selfNote = "day5" }
        instrument(store)

        store.applyRecurringEdit(
            seriesEvent: store.findCalendarEvent(id: seriesID)!,
            occurrenceDate: day(3),
            scope: .following
        ) { $0.title = "New" }

        let calendarCommits = trace.filter { $0 == "commit:\(StorageSlot.calendarEvents.rawValue)" }
        XCTAssertEqual(calendarCommits.count, 1,
                       "the new series and the capped old series must land together: \(trace)")
        XCTAssertEqual(trace.first, "commit:\(StorageSlot.calendarEvents.rawValue)",
                       "the calendar state commits before the record reindex")

        // Observable behaviour is unchanged: two series, the old one capped,
        // the day-5 records re-homed onto the new one.
        let newSeries = store.rawCalendarEvents.first { $0.isRecurringSeries && $0.id != seriesID }
        XCTAssertNotNil(newSeries)
        XCTAssertEqual(store.findCalendarEvent(id: seriesID)?.repeatEndType, .onDate)
        XCTAssertEqual(newSeries?.title, "New")
        XCTAssertEqual(
            store.calendarEventLogRecords
                .first { calendar.isDate($0.occurrenceDate, inSameDayAs: day(5)) }?.baseSeriesEventID,
            newSeries?.id
        )
        XCTAssertEqual(
            store.calendarEventFeedbackRecords
                .first { calendar.isDate($0.occurrenceDate, inSameDayAs: day(5)) }?.baseSeriesEventID,
            newSeries?.id
        )
    }

    /// The single commit must still be durable — one `rename(2)` carrying both
    /// series, visible to a store built from scratch against the same files.
    func testFollowingEditIsDurableAfterItsSingleCommit() {
        let store = makeStore()
        let calendar = Calendar.current
        let day0 = calendar.startOfDay(for: Date())
        let seriesID = UUID()
        var series = Event(
            id: seriesID,
            title: "Daily",
            timeRanges: [.init(start: day0.addingTimeInterval(9 * 3600),
                               end: day0.addingTimeInterval(10 * 3600))],
            type: "Study"
        )
        series.repeatUnit = .day
        series.repeatInterval = 1
        store.addCalendarEvent(series)

        store.applyRecurringEdit(
            seriesEvent: store.findCalendarEvent(id: seriesID)!,
            occurrenceDate: calendar.date(byAdding: .day, value: 3, to: day0)!,
            scope: .following
        ) { $0.title = "New" }

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.rawCalendarEvents.count, 2)
        XCTAssertEqual(reloaded.findCalendarEvent(id: seriesID)?.repeatEndType, .onDate)
        XCTAssertTrue(reloaded.rawCalendarEvents.contains { $0.id != seriesID && $0.title == "New" })
    }

    // MARK: - Reference set for the launch sweep

    /// Every producer of an image ref has to be in the set, or the launch
    /// sweep would treat a live photo as abandoned. Photos hang off events
    /// (both arrays) and off timeline notes inside log records.
    func testReferencedAssetPathsCoverEventsAndTimelineNotes() {
        var todo = Event(title: "Todo", timeRanges: [], kind: .todo)
        todo.agenticIntake = AgenticIntakeRecord(
            rawText: "", images: [imageRef("todo/a.jpg")], source: .classicFallback
        )
        let event = photoEvent("Event", id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
        var log = CalendarEventLogRecord(
            id: CalendarOccurrenceKey.make(for: event, occurrenceDate: Date()),
            eventID: event.id,
            baseSeriesEventID: nil,
            occurrenceDate: Date()
        )
        log.timelineItems = [
            .note(EventLogTimelineNote(text: "note", source: "test", images: [imageRef("note/b.jpg")]))
        ]

        let paths = EventStore.referencedAssetRelativePaths(
            events: [todo],
            calendarEvents: [event],
            logRecords: [log],
            feedbackRecords: []
        )

        XCTAssertEqual(paths, [
            "todo/a.jpg",
            "11111111-1111-1111-1111-111111111111/photo.jpg",
            "note/b.jpg"
        ])
    }

    // MARK: - The launch sweep's refusals

    /// The sweep never RUNS under XCTest — `ownsSharedAssetDirectory` is false
    /// at every test location, because the asset directory is one path for the
    /// whole container and a test sweeping it would delete the dogfood user's
    /// photos. The decision to run is therefore the only reachable part, and
    /// it is the part that can destroy a photo, so it is what these test.
    private func slotURL(_ slot: StorageSlot, backup: Bool = false) throws -> URL {
        try location.directoryURL()
            .appendingPathComponent(backup ? slot.backupFilename : slot.filename)
    }

    /// A real file, in a THROWAWAY directory the sweep is pointed at
    /// explicitly. The shared asset directory is still never touched — no test
    /// location owns it, and these tests never let the launch path pick it.
    @discardableResult
    private func writeRealPhoto(_ relativePath: String) throws -> URL {
        let url = assetDirectory.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: url)
        return url
    }

    private func photoExists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(
            atPath: assetDirectory.appendingPathComponent(relativePath).path)
    }

    /// The gap the fault gate could not see (adopted from QA probe P9): a
    /// corrupt primary is RECOVERED from the `.bak` hardlink, which is the
    /// PREVIOUS generation. The recovery succeeds, so nothing is frozen and
    /// `storageFaults` stays empty; the survivors keep the store non-empty.
    /// Every row committed in the lost generation is silently absent from the
    /// reference set, and its photos therefore read as abandoned — with no
    /// race at all.
    ///
    /// The asymmetry is the whole point: the lost EVENT is still on disk (the
    /// corrupt primary is quarantined, not deleted) and may also be in the
    /// cloud; a local-only photo the sweep unlinks has neither.
    func testLaunchSweepIsRefusedAfterABackupRecovery() throws {
        let store = makeStore()
        let older = photoEvent("Older")
        store.addCalendarEvent(older)                           // commit N-1
        let newer = photoEvent("Newer", daysFromNow: 1)
        store.addCalendarEvent(newer)                           // commit N
        let olderPath = "\(older.id.uuidString)/photo.jpg"
        let newerPath = "\(newer.id.uuidString)/photo.jpg"
        try writeRealPhoto(olderPath)
        try writeRealPhoto(newerPath)

        // Corrupt ONLY the primary. The backup still holds generation N-1, so
        // this is a recovery, not a freeze.
        try Data("not json".utf8).write(to: try slotURL(.calendarEvents))

        let recovered = makeStore()
        XCTAssertEqual(recovered.slotProvenance[.calendarEvents], .backup)
        XCTAssertTrue(recovered.storageFaults.isEmpty,
                      "a successful recovery raises no fault — which is why the fault gate cannot catch this")
        XCTAssertFalse(recovered.rawCalendarEvents.isEmpty,
                       "and the survivors keep the empty-store gate from catching it either")
        XCTAssertFalse(recovered.rawCalendarEvents.contains { $0.id == newer.id },
                       "fixture: the newest generation is the one the recovery lost")

        XCTAssertNotNil(recovered.startupOrphanAssetSweepRefusal,
                        "a reference set one generation stale must not be swept against")

        // ...and the refusal is load-bearing, not decorative. Run the sweep it
        // suppressed, against a throwaway directory, and the lost generation's
        // photo is destroyed — while its event is still recoverable.
        let referenced = EventStore.referencedAssetRelativePaths(
            events: recovered.events,
            calendarEvents: recovered.rawCalendarEvents,
            logRecords: recovered.calendarEventLogRecords,
            feedbackRecords: recovered.calendarEventFeedbackRecords
        )
        let suppressed = AgenticIntakeAssetGarbageCollector(baseDirectoryURL: assetDirectory)
            .sweep(referencedRelativePaths: referenced,
                   now: Date().addingTimeInterval(72 * 3600))
        XCTAssertEqual(suppressed.deletedRelativePaths, [newerPath],
                       "what the refusal is protecting: \(suppressed.summary)")
        XCTAssertTrue(photoExists(olderPath))
    }

    /// A frozen slot contributes no paths at all.
    func testLaunchSweepIsRefusedWhileASlotIsFrozen() throws {
        let store = makeStore()
        store.addCalendarEvent(photoEvent("A"))
        try Data("shredded".utf8).write(to: try slotURL(.calendarEvents))
        try? FileManager.default.removeItem(at: try slotURL(.calendarEvents, backup: true))

        let relaunched = makeStore()
        XCTAssertTrue(relaunched.isSlotFrozen(.calendarEvents))
        XCTAssertNotNil(relaunched.startupOrphanAssetSweepRefusal)
    }

    /// A store that came up with nothing in it reads every file as abandoned.
    func testLaunchSweepIsRefusedWhenNoRowsLoaded() {
        XCTAssertNotNil(makeStore().startupOrphanAssetSweepRefusal)
    }

    /// The other direction, and the reason the refusals are asserted one at a
    /// time: a gate that never opens is a silent leak of the user's disk, and
    /// nothing else in the app would report it.
    func testLaunchSweepIsAllowedOnAnOrdinaryLaunch() {
        let store = makeStore()
        store.addCalendarEvent(photoEvent("A"))

        let relaunched = makeStore()
        XCTAssertEqual(relaunched.slotProvenance[.calendarEvents], .primary)
        XCTAssertNil(relaunched.startupOrphanAssetSweepRefusal)
    }
}
