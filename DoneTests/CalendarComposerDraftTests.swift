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
}
