import XCTest
@testable import Done

final class CalendarComposerDraftTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "CalendarComposerDraftTests")!
        defaults.removePersistentDomain(forName: "CalendarComposerDraftTests")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "CalendarComposerDraftTests")
        super.tearDown()
    }

    private func makeDraft(
        title: String = "Dentist",
        note: String = "",
        location: String = "",
        peopleIDs: [UUID] = [],
        deadline: Date? = nil,
        savedAt: Date = Date()
    ) -> CalendarComposerDraft {
        CalendarComposerDraft(
            title: title,
            kind: .event,
            deadline: deadline,
            typeTitle: "Errand",
            isAllDay: false,
            startTime: savedAt.addingTimeInterval(3600),
            endTime: savedAt.addingTimeInterval(7200),
            location: location,
            note: note,
            repeatUnit: .none,
            repeatInterval: 1,
            repeatEndType: .none,
            repeatEndDate: nil,
            repeatEndCount: 10,
            peopleIDs: peopleIDs,
            savedAt: savedAt
        )
    }

    // MARK: - Round trip

    func testSaveThenLoadFreshRoundTrips() {
        let draft = makeDraft(note: "bring x-rays", location: "Main St")
        CalendarComposerDraftStore.save(draft, defaults: defaults)
        XCTAssertEqual(CalendarComposerDraftStore.loadFresh(defaults: defaults), draft)
    }

    func testClearRemovesDraft() {
        CalendarComposerDraftStore.save(makeDraft(), defaults: defaults)
        CalendarComposerDraftStore.clear(defaults: defaults)
        XCTAssertNil(CalendarComposerDraftStore.loadFresh(defaults: defaults))
    }

    // MARK: - Freshness

    func testExpiredDraftIsDroppedAndCleared() {
        let stale = makeDraft(savedAt: Date().addingTimeInterval(-CalendarComposerDraftStore.maxAge - 60))
        CalendarComposerDraftStore.save(stale, defaults: defaults)
        XCTAssertNil(CalendarComposerDraftStore.loadFresh(defaults: defaults))
        // The blob itself must be gone so it can't resurface after a clock change.
        XCTAssertNil(defaults.data(forKey: CalendarComposerDraftStore.storageKey))
    }

    func testDraftJustInsideMaxAgeSurvives() {
        let nearStale = makeDraft(savedAt: Date().addingTimeInterval(-CalendarComposerDraftStore.maxAge + 60))
        CalendarComposerDraftStore.save(nearStale, defaults: defaults)
        XCTAssertNotNil(CalendarComposerDraftStore.loadFresh(defaults: defaults))
    }

    func testFutureSavedAtIsDistrusted() {
        let future = makeDraft(savedAt: Date().addingTimeInterval(3600))
        CalendarComposerDraftStore.save(future, defaults: defaults)
        XCTAssertNil(CalendarComposerDraftStore.loadFresh(defaults: defaults))
    }

    func testCorruptBlobIsDroppedAndCleared() {
        defaults.set(Data("not json".utf8), forKey: CalendarComposerDraftStore.storageKey)
        XCTAssertNil(CalendarComposerDraftStore.loadFresh(defaults: defaults))
        XCTAssertNil(defaults.data(forKey: CalendarComposerDraftStore.storageKey))
    }

    // MARK: - Meaningfulness

    func testTypeAndTimeAloneAreNotMeaningful() {
        let draft = makeDraft(title: "   ")
        XCTAssertFalse(draft.isMeaningful)
    }

    func testTitleNoteLocationPeopleDeadlineEachQualify() {
        XCTAssertTrue(makeDraft(title: "x").isMeaningful)
        XCTAssertTrue(makeDraft(title: "", note: "x").isMeaningful)
        XCTAssertTrue(makeDraft(title: "", location: "x").isMeaningful)
        XCTAssertTrue(makeDraft(title: "", peopleIDs: [UUID()]).isMeaningful)
        XCTAssertTrue(makeDraft(title: "", deadline: Date()).isMeaningful)
    }

    func testMeaninglessDraftDoesNotLoad() {
        CalendarComposerDraftStore.save(makeDraft(title: "  "), defaults: defaults)
        XCTAssertNil(CalendarComposerDraftStore.loadFresh(defaults: defaults))
    }

    // MARK: - Restore eligibility

    func testCallerContentBlocksRestore() {
        XCTAssertTrue(CalendarComposerDraft.callerProvidedContent(
            initialTitle: "Prefilled", initialNote: "", initialLocation: "", hasAgenticIntake: false))
        XCTAssertTrue(CalendarComposerDraft.callerProvidedContent(
            initialTitle: "", initialNote: "prefilled", initialLocation: "", hasAgenticIntake: false))
        XCTAssertTrue(CalendarComposerDraft.callerProvidedContent(
            initialTitle: "", initialNote: "", initialLocation: "prefilled", hasAgenticIntake: false))
        XCTAssertTrue(CalendarComposerDraft.callerProvidedContent(
            initialTitle: "", initialNote: "", initialLocation: "", hasAgenticIntake: true))
    }

    func testEmptyCallerAllowsRestore() {
        XCTAssertFalse(CalendarComposerDraft.callerProvidedContent(
            initialTitle: "  ", initialNote: "", initialLocation: "", hasAgenticIntake: false))
    }

    // MARK: - fieldsEqual

    func testFieldsEqualIgnoresSavedAt() {
        let a = makeDraft(savedAt: Date())
        var b = a
        b.savedAt = Date().addingTimeInterval(-999)
        XCTAssertTrue(a.fieldsEqual(b))
        b.title = "changed"
        XCTAssertFalse(a.fieldsEqual(b))
    }

    // MARK: - Edit draft store

    private func makeEditDraft(
        eventID: UUID,
        base: CalendarComposerDraft,
        editedTitle: String = "Dentist (moved)",
        savedAt: Date = Date()
    ) -> CalendarEditDraft {
        var edited = base
        edited.title = editedTitle
        return CalendarEditDraft(eventID: eventID, base: base, edited: edited, savedAt: savedAt)
    }

    func testEditDraftRestoresWhenBaseStillMatches() {
        let id = UUID()
        let base = makeDraft()
        CalendarEditDraftStore.save(makeEditDraft(eventID: id, base: base), defaults: defaults)
        let restored = CalendarEditDraftStore.loadFresh(eventID: id, current: base, defaults: defaults)
        XCTAssertEqual(restored?.title, "Dentist (moved)")
    }

    func testEditDraftDiscardedWhenEventChangedElsewhere() {
        let id = UUID()
        let base = makeDraft()
        CalendarEditDraftStore.save(makeEditDraft(eventID: id, base: base), defaults: defaults)
        var movedByCanvasDrag = base
        movedByCanvasDrag.startTime = base.startTime.addingTimeInterval(1800)
        XCTAssertNil(CalendarEditDraftStore.loadFresh(eventID: id, current: movedByCanvasDrag, defaults: defaults))
        // Dead draft must be gone, not lurking.
        XCTAssertNil(defaults.data(forKey: CalendarEditDraftStore.storageKey))
    }

    func testEditDraftForOtherEventIsLeftIntact() {
        let idA = UUID(), idB = UUID()
        let base = makeDraft()
        CalendarEditDraftStore.save(makeEditDraft(eventID: idA, base: base), defaults: defaults)
        XCTAssertNil(CalendarEditDraftStore.loadFresh(eventID: idB, current: base, defaults: defaults))
        // Opening event B must not destroy event A's pending rescue.
        XCTAssertNotNil(defaults.data(forKey: CalendarEditDraftStore.storageKey))
        XCTAssertEqual(
            CalendarEditDraftStore.loadFresh(eventID: idA, current: base, defaults: defaults)?.title,
            "Dentist (moved)"
        )
    }

    func testEditDraftScopedClearOnlyRemovesOwnEvent() {
        let idA = UUID(), idB = UUID()
        let base = makeDraft()
        CalendarEditDraftStore.save(makeEditDraft(eventID: idA, base: base), defaults: defaults)
        CalendarEditDraftStore.clear(eventID: idB, defaults: defaults)
        XCTAssertNotNil(defaults.data(forKey: CalendarEditDraftStore.storageKey))
        CalendarEditDraftStore.clear(eventID: idA, defaults: defaults)
        XCTAssertNil(defaults.data(forKey: CalendarEditDraftStore.storageKey))
    }

    func testStaleEditDraftIsDroppedAndCleared() {
        let id = UUID()
        let base = makeDraft()
        let stale = makeEditDraft(
            eventID: id, base: base,
            savedAt: Date().addingTimeInterval(-CalendarEditDraftStore.maxAge - 60)
        )
        CalendarEditDraftStore.save(stale, defaults: defaults)
        XCTAssertNil(CalendarEditDraftStore.loadFresh(eventID: id, current: base, defaults: defaults))
        XCTAssertNil(defaults.data(forKey: CalendarEditDraftStore.storageKey))
    }

    // MARK: - Detail composer draft store (interrupt/parallel)

    private func makeDetailDraft(
        mode: CalendarDetailComposerDraft.Mode = .interrupt,
        occurrenceKey: String = "occ-1",
        title: String = "Phone call",
        savedAt: Date = Date()
    ) -> CalendarDetailComposerDraft {
        CalendarDetailComposerDraft(
            mode: mode,
            occurrenceKey: occurrenceKey,
            title: title,
            typeTitle: "Social",
            note: "",
            didExplicitlySelectType: true,
            startProgress: 0.5,
            endProgress: 0.75,
            savedAt: savedAt
        )
    }

    func testDetailDraftRoundTripsForSameModeAndOccurrence() {
        CalendarDetailComposerDraftStore.save(makeDetailDraft(), defaults: defaults)
        let loaded = CalendarDetailComposerDraftStore.loadFresh(
            mode: .interrupt, occurrenceKey: "occ-1", defaults: defaults)
        XCTAssertEqual(loaded?.title, "Phone call")
        XCTAssertEqual(loaded?.didExplicitlySelectType, true)
    }

    func testDetailDraftNotReturnedForOtherModeOrOccurrenceButKept() {
        CalendarDetailComposerDraftStore.save(makeDetailDraft(), defaults: defaults)
        XCTAssertNil(CalendarDetailComposerDraftStore.loadFresh(
            mode: .parallel, occurrenceKey: "occ-1", defaults: defaults))
        XCTAssertNil(CalendarDetailComposerDraftStore.loadFresh(
            mode: .interrupt, occurrenceKey: "occ-2", defaults: defaults))
        XCTAssertNotNil(defaults.data(forKey: CalendarDetailComposerDraftStore.storageKey))
    }

    func testDetailDraftScopedClear() {
        CalendarDetailComposerDraftStore.save(makeDetailDraft(), defaults: defaults)
        CalendarDetailComposerDraftStore.clear(mode: .interrupt, occurrenceKey: "occ-9", defaults: defaults)
        XCTAssertNotNil(defaults.data(forKey: CalendarDetailComposerDraftStore.storageKey))
        CalendarDetailComposerDraftStore.clear(mode: .interrupt, occurrenceKey: "occ-1", defaults: defaults)
        XCTAssertNil(defaults.data(forKey: CalendarDetailComposerDraftStore.storageKey))
    }

    func testStaleDetailDraftClears() {
        let stale = makeDetailDraft(savedAt: Date().addingTimeInterval(-CalendarDetailComposerDraftStore.maxAge - 60))
        CalendarDetailComposerDraftStore.save(stale, defaults: defaults)
        XCTAssertNil(CalendarDetailComposerDraftStore.loadFresh(
            mode: .interrupt, occurrenceKey: "occ-1", defaults: defaults))
        XCTAssertNil(defaults.data(forKey: CalendarDetailComposerDraftStore.storageKey))
    }

    func testSliderOnlyDetailDraftIsNotMeaningful() {
        XCTAssertFalse(makeDetailDraft(title: "  ").isMeaningful)
        XCTAssertTrue(makeDetailDraft(title: "x").isMeaningful)
    }

    func testSnapshotOfEventMirrorsEditSeeding() {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var event = Event(
            title: "Standup",
            note: "daily",
            location: "Zoom",
            timeRanges: [Event.TimeRange(start: start, end: start.addingTimeInterval(1800))],
            type: "Work"
        )
        event.peopleIDs = [UUID()]
        let snap = CalendarComposerDraft.snapshot(of: event)
        XCTAssertEqual(snap.title, "Standup")
        XCTAssertEqual(snap.typeTitle, "Work")
        XCTAssertEqual(snap.note, "daily")
        XCTAssertEqual(snap.location, "Zoom")
        XCTAssertEqual(snap.startTime, start)
        XCTAssertEqual(snap.peopleIDs, event.peopleIDs)
        // Same event, snapshotted twice → identical fields (fingerprint stability).
        XCTAssertTrue(snap.fieldsEqual(CalendarComposerDraft.snapshot(of: event)))
    }
}
