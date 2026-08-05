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

    func testEditDraftNotRestoredWhenEventChangedElsewhere() {
        let id = UUID()
        let base = makeDraft()
        CalendarEditDraftStore.save(makeEditDraft(eventID: id, base: base), defaults: defaults)
        var movedByCanvasDrag = base
        movedByCanvasDrag.startTime = base.startTime.addingTimeInterval(1800)
        XCTAssertNil(CalendarEditDraftStore.loadFresh(eventID: id, current: movedByCanvasDrag, defaults: defaults))
        // NOT cleared: loadFresh runs from view init, which SwiftUI re-
        // evaluates on every parent invalidation — clearing here would let a
        // mid-session external move destroy a rescue this session just
        // wrote. The dead draft dies by expiry or the next session's write.
        XCTAssertNotNil(defaults.data(forKey: CalendarEditDraftStore.storageKey))
        // And with the original base it still restores.
        XCTAssertNotNil(CalendarEditDraftStore.loadFresh(eventID: id, current: base, defaults: defaults))
    }

    func testFutureSavedAtEditDraftIsDistrusted() {
        let id = UUID()
        let base = makeDraft()
        let future = makeEditDraft(eventID: id, base: base, savedAt: Date().addingTimeInterval(3600))
        CalendarEditDraftStore.save(future, defaults: defaults)
        XCTAssertNil(CalendarEditDraftStore.loadFresh(eventID: id, current: base, defaults: defaults))
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

    func testFutureSavedAtDetailDraftIsDistrusted() {
        let future = makeDetailDraft(savedAt: Date().addingTimeInterval(3600))
        CalendarDetailComposerDraftStore.save(future, defaults: defaults)
        XCTAssertNil(CalendarDetailComposerDraftStore.loadFresh(
            mode: .interrupt, occurrenceKey: "occ-1", defaults: defaults))
    }

    func testSnapshotNormalizesLeftoverRepeatEndDate() {
        // An event can carry a leftover repeatEndDate under a non-.onDate
        // end type (set → flipped back). The form-side snapshot nils it, so
        // the event-side snapshot must too — otherwise an untouched edit
        // session fingerprints as "changed" on every phase departure.
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var event = Event(
            title: "Standup",
            timeRanges: [Event.TimeRange(start: start, end: start.addingTimeInterval(1800))],
            type: "Work"
        )
        event.repeatUnit = .none
        event.repeatEndType = .none
        event.repeatEndDate = start.addingTimeInterval(86400 * 30)
        let snap = CalendarComposerDraft.snapshot(of: event)
        XCTAssertNil(snap.repeatEndDate)
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

    // MARK: - Create-slot write policy

    func testMeaningfulSnapshotAlwaysSaves() {
        for resumes in [false, true] {
            for wrote in [false, true] {
                XCTAssertEqual(
                    calendarCreateDraftSlotAction(
                        snapshotIsMeaningful: true,
                        resumesDraft: resumes,
                        wroteDraftSlot: wrote
                    ),
                    .save,
                    "resumes=\(resumes) wrote=\(wrote)"
                )
            }
        }
    }

    func testEmptiedFormClearsOnlyASlotThisSessionOwns() {
        // Owned (resumed or already written) → an emptied form must not let
        // the stale draft resurrect.
        XCTAssertEqual(
            calendarCreateDraftSlotAction(
                snapshotIsMeaningful: false, resumesDraft: true, wroteDraftSlot: false
            ),
            .clear
        )
        XCTAssertEqual(
            calendarCreateDraftSlotAction(
                snapshotIsMeaningful: false, resumesDraft: false, wroteDraftSlot: true
            ),
            .clear
        )
        // Not owned → a plain drag-create must not destroy a rescue pending
        // for a session it never displayed.
        XCTAssertEqual(
            calendarCreateDraftSlotAction(
                snapshotIsMeaningful: false, resumesDraft: false, wroteDraftSlot: false
            ),
            .leaveAlone
        )
    }

    // MARK: - Session-end policy (the swipe-down asymmetry)

    func testSwipeDownPreservesTypedContentInsteadOfDiscardingIt() {
        // The regression this policy exists for: user drags out a slot, types
        // a title, then swipes the sheet away by accident. Nothing was ever
        // written (no scene change), and the old policy cleared on every
        // dismissal — so the input evaporated with no banner to rescue it.
        XCTAssertEqual(
            calendarCreateDraftSessionEndAction(
                pendingSnapshotIsMeaningful: true,
                usesDraftSlot: true,
                resumesDraft: false,
                wroteDraftSlot: false
            ),
            .save
        )
    }

    func testExplicitEndDiscardsWhatASwipeDownWouldHaveKept() {
        // Same session state as above, but Done/Cancel (nil snapshot): an
        // explicit decision is allowed to destroy content.
        XCTAssertEqual(
            calendarCreateDraftSessionEndAction(
                pendingSnapshotIsMeaningful: nil,
                usesDraftSlot: true,
                resumesDraft: false,
                wroteDraftSlot: true
            ),
            .clear
        )
        // ...and an explicit end that never owned the slot still leaves a
        // rescue pending for someone else alone.
        XCTAssertEqual(
            calendarCreateDraftSessionEndAction(
                pendingSnapshotIsMeaningful: nil,
                usesDraftSlot: true,
                resumesDraft: false,
                wroteDraftSlot: false
            ),
            .leaveAlone
        )
    }

    func testSwipeDownOfAnEmptyUnownedFormTouchesNothing() {
        XCTAssertEqual(
            calendarCreateDraftSessionEndAction(
                pendingSnapshotIsMeaningful: false,
                usesDraftSlot: true,
                resumesDraft: false,
                wroteDraftSlot: false
            ),
            .leaveAlone
        )
    }

    func testPrefilledSessionNeverWritesTheSlotEvenOnSwipeDown() {
        // usesDraftSlot == false is a caller-prefilled session (reminder →
        // event, agentic intake). It must not write the slot in EITHER
        // direction — a swipe-down there would otherwise overwrite a rescue
        // pending for the plain composer this session never showed.
        XCTAssertEqual(
            calendarCreateDraftSessionEndAction(
                pendingSnapshotIsMeaningful: true,
                usesDraftSlot: false,
                resumesDraft: false,
                wroteDraftSlot: false
            ),
            .leaveAlone
        )
    }

    func testResumingSessionThatNeverDisplayedTheSlotMustNotClearIt() {
        // `restoredDraft` requires resumesDraft AND usesDraftSlot, so a
        // resuming session carrying caller prefill shows the user nothing —
        // clearing on its way out would destroy a rescue never displayed.
        for meaningful: Bool? in [nil, true, false] {
            XCTAssertEqual(
                calendarCreateDraftSessionEndAction(
                    pendingSnapshotIsMeaningful: meaningful,
                    usesDraftSlot: false,
                    resumesDraft: true,
                    wroteDraftSlot: false
                ),
                .leaveAlone,
                "pendingMeaningful=\(String(describing: meaningful))"
            )
        }
    }

    /// Full-grid traversal so no combination is left unasserted — the
    /// hand-picked cases above are the readable documentation, this is the
    /// exhaustive net.
    func testSessionEndActionFullGrid() {
        for meaningful: Bool? in [nil, true, false] {
            for usesSlot in [false, true] {
                for resumes in [false, true] {
                    for wrote in [false, true] {
                        let owns = (resumes && usesSlot) || wrote
                        let expected: CalendarComposerDraftSlotAction
                        if let meaningful, usesSlot {
                            expected = meaningful ? .save : (owns ? .clear : .leaveAlone)
                        } else {
                            expected = owns ? .clear : .leaveAlone
                        }
                        XCTAssertEqual(
                            calendarCreateDraftSessionEndAction(
                                pendingSnapshotIsMeaningful: meaningful,
                                usesDraftSlot: usesSlot,
                                resumesDraft: resumes,
                                wroteDraftSlot: wrote
                            ),
                            expected,
                            "meaningful=\(String(describing: meaningful)) uses=\(usesSlot) resumes=\(resumes) wrote=\(wrote)"
                        )
                    }
                }
            }
        }
    }

    /// A new create session overwriting a rescue pending from an earlier one
    /// is a KNOWN and accepted consequence of the single-slot design — pinned
    /// here so it can't change silently. Continuous writes make it reachable
    /// from one keystroke, where it previously needed a scene departure.
    func testNewSessionOverwritesAnEarlierRescueThenExplicitEndClearsIt() {
        var earlier = makeDraft(title: "dinner with Ana")
        earlier.note = "book the table"
        CalendarComposerDraftStore.save(earlier, defaults: defaults)

        // Fresh session (didn't resume, hasn't written) types one character.
        XCTAssertEqual(
            calendarCreateDraftSlotAction(
                snapshotIsMeaningful: true, resumesDraft: false, wroteDraftSlot: false
            ),
            .save
        )
        CalendarComposerDraftStore.save(makeDraft(title: "gym"), defaults: defaults)
        XCTAssertEqual(CalendarComposerDraftStore.loadFresh(defaults: defaults)?.title, "gym")

        // ...and its explicit end wipes the slot entirely: "dinner with Ana"
        // is gone for good.
        XCTAssertEqual(
            calendarCreateDraftSessionEndAction(
                pendingSnapshotIsMeaningful: nil,
                usesDraftSlot: true,
                resumesDraft: false,
                wroteDraftSlot: true
            ),
            .clear
        )
        CalendarComposerDraftStore.clear(defaults: defaults)
        XCTAssertNil(CalendarComposerDraftStore.loadFresh(defaults: defaults))
    }

    /// Done is just an explicit end — it may only clear a slot this session
    /// owns. Regression pin: a hand-rolled `usesDraftSlot || resumesDraft`
    /// gate on the create path once wiped an unrelated pending rescue when
    /// the user pressed Done on a form they had typed nothing into.
    func testDoneOnAnUntouchedFormMustNotClearSomeoneElsesRescue() {
        CalendarComposerDraftStore.save(makeDraft(title: "dinner with Ana"), defaults: defaults)

        // Plain drag-create: owns the slot type-wise, but never wrote it
        // (nothing meaningful was ever typed), so it owns no content.
        XCTAssertEqual(
            calendarCreateDraftSessionEndAction(
                pendingSnapshotIsMeaningful: nil,
                usesDraftSlot: true,
                resumesDraft: false,
                wroteDraftSlot: false
            ),
            .leaveAlone
        )
        XCTAssertEqual(
            CalendarComposerDraftStore.loadFresh(defaults: defaults)?.title,
            "dinner with Ana"
        )

        // Same session once it HAS written the slot: now it owns the content
        // and Done must consume it, or the banner would offer the
        // just-created event back for a second creation.
        XCTAssertEqual(
            calendarCreateDraftSessionEndAction(
                pendingSnapshotIsMeaningful: nil,
                usesDraftSlot: true,
                resumesDraft: false,
                wroteDraftSlot: true
            ),
            .clear
        )
    }

    /// The fingerprint that drives the continuous write is a whole-struct
    /// comparison, so any user-editable field missing from it would silently
    /// stop triggering writes. Mutating each field must break equality.
    func testEveryFieldParticipatesInFieldsEqual() {
        let base = makeDraft(title: "base")
        var mutations: [(String, CalendarComposerDraft)] = []
        func mutate(_ name: String, _ transform: (inout CalendarComposerDraft) -> Void) {
            var copy = base
            transform(&copy)
            mutations.append((name, copy))
        }
        mutate("title") { $0.title = "other" }
        mutate("kind") { $0.kind = $0.kind == .todo ? .event : .todo }
        mutate("deadline") { $0.deadline = Date(timeIntervalSinceReferenceDate: 900_000_000) }
        mutate("typeTitle") { $0.typeTitle = "Work-changed" }
        mutate("isAllDay") { $0.isAllDay.toggle() }
        mutate("startTime") { $0.startTime = $0.startTime.addingTimeInterval(60) }
        mutate("endTime") { $0.endTime = $0.endTime.addingTimeInterval(60) }
        mutate("location") { $0.location = "elsewhere" }
        mutate("note") { $0.note = "changed" }
        mutate("repeatUnit") { $0.repeatUnit = $0.repeatUnit == .week ? .day : .week }
        mutate("repeatInterval") { $0.repeatInterval += 1 }
        mutate("repeatEndType") { $0.repeatEndType = $0.repeatEndType == .onDate ? .afterCount : .onDate }
        mutate("repeatEndDate") { $0.repeatEndDate = Date(timeIntervalSinceReferenceDate: 910_000_000) }
        mutate("repeatEndCount") { $0.repeatEndCount += 1 }
        mutate("peopleIDs") { $0.peopleIDs = [UUID()] }

        for (name, mutated) in mutations {
            XCTAssertFalse(
                base.fieldsEqual(mutated),
                "changing \(name) must be visible to the draft fingerprint"
            )
        }
    }

    func testResumedSessionSwipedAwayEmptyClearsRatherThanResurrects() {
        // User resumed a draft from the banner, wiped the fields, then swiped
        // away. Keeping the old blob would make the banner reappear with
        // content the user just deleted.
        XCTAssertEqual(
            calendarCreateDraftSessionEndAction(
                pendingSnapshotIsMeaningful: false,
                usesDraftSlot: true,
                resumesDraft: true,
                wroteDraftSlot: false
            ),
            .clear
        )
    }
}
