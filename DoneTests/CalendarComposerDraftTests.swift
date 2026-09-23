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

    // MARK: - Detail slot takeover instrumentation (gh#185 / gh#132)

    /// `DiagnosticTrail` is process-global and file-backed (the same reality
    /// `DiagnosticTrailTests` documents), so each test here clears it around
    /// itself and asserts only on lines it caused itself.
    private func withCleanDiagnosticTrail(_ body: () -> Void) {
        DiagnosticTrail.clear()
        defer { DiagnosticTrail.clear() }
        body()
    }

    /// Reads the takeover lines back out of the REAL trail file — the store's
    /// category constant is the only thing shared with the implementation, so
    /// these tests fail if the event stops reaching disk, not just if a
    /// mirrored condition drifts.
    private func takeoverTrailLines() -> [String] {
        DiagnosticTrail.combinedText()
            .split(separator: "\n")
            .filter { $0.contains(" \(CalendarDetailComposerDraftStore.takeoverTrailCategory) ") }
            .map(String.init)
    }

    func testCrossOccurrenceTakeoverIsLastWriterWinsAndRecordsOneTrailEvent() {
        withCleanDiagnosticTrail {
            CalendarDetailComposerDraftStore.save(
                makeDetailDraft(occurrenceKey: "occ-A", title: "call the bank"), defaults: defaults)
            let takeover = makeDetailDraft(mode: .parallel, occurrenceKey: "occ-B", title: "s")
            CalendarDetailComposerDraftStore.save(takeover, defaults: defaults)
            // Follow-up keystrokes of the SAME takeover session: still one event.
            var edited = takeover
            edited.title = "side quest"
            CalendarDetailComposerDraftStore.save(edited, defaults: defaults)

            // The honest single-slot contract: B owns the slot, A's rescue is gone.
            XCTAssertNil(CalendarDetailComposerDraftStore.loadFresh(
                mode: .interrupt, occurrenceKey: "occ-A", defaults: defaults))
            XCTAssertEqual(
                CalendarDetailComposerDraftStore.loadFresh(
                    mode: .parallel, occurrenceKey: "occ-B", defaults: defaults)?.title,
                "side quest")

            let lines = takeoverTrailLines()
            XCTAssertEqual(lines.count, 1, "one takeover must record exactly one event, got: \(lines)")
            let line = lines.first ?? ""
            XCTAssertTrue(line.contains("old=interrupt/occ-A"), line)
            XCTAssertTrue(line.contains("new=parallel/occ-B"), line)
            XCTAssertTrue(line.contains("oldHadContent=true"), line)
            // The trail is a file the user exports and hands to someone:
            // occurrence keys only, never what was typed. Asserted against
            // the full trail line so ANY leak of either title is caught.
            XCTAssertFalse(line.contains("call the bank"), line)
            XCTAssertFalse(line.contains("side quest"), line)
        }
    }

    /// gh#132's consumer counts takeovers by grepping the exported trail for
    /// this literal. Pinned as a string on purpose: a rename of the constant
    /// would keep every other test green (they read the constant) while
    /// silently zeroing the downstream measurement.
    func testTakeoverTrailCategoryLiteralIsPinned() {
        XCTAssertEqual(CalendarDetailComposerDraftStore.takeoverTrailCategory, "DraftSlot")
    }

    func testSameOccurrenceContinuousWritesRecordNoTakeoverEvent() {
        withCleanDiagnosticTrail {
            CalendarDetailComposerDraftStore.save(
                makeDetailDraft(title: "phone"), defaults: defaults)
            CalendarDetailComposerDraftStore.save(
                makeDetailDraft(title: "phone call with"), defaults: defaults)
            CalendarDetailComposerDraftStore.save(
                makeDetailDraft(title: "phone call with mom"), defaults: defaults)
            XCTAssertEqual(
                takeoverTrailLines(), [],
                "per-keystroke writes of one session must not reach the trail")
        }
    }

    func testEmptyIncumbentTakeoverRecordsEventWithOldHadContentFalse() {
        withCleanDiagnosticTrail {
            // Whitespace title + empty note: trivially empty per `isMeaningful`
            // (slider position and type selection alone are one gesture to redo).
            CalendarDetailComposerDraftStore.save(
                makeDetailDraft(occurrenceKey: "occ-A", title: "   "), defaults: defaults)
            CalendarDetailComposerDraftStore.save(
                makeDetailDraft(occurrenceKey: "occ-B", title: "real content"), defaults: defaults)
            let lines = takeoverTrailLines()
            XCTAssertEqual(
                lines.count, 1,
                "a hand-over of an empty slot still counts toward gh#132's frequency, got: \(lines)")
            let line = lines.first ?? ""
            XCTAssertTrue(line.contains("old=interrupt/occ-A"), line)
            XCTAssertTrue(line.contains("new=interrupt/occ-B"), line)
            XCTAssertTrue(
                line.contains("oldHadContent=false"), 
                "an empty incumbent is churn, not harm — the flag must say so: \(line)")
        }
    }

    // MARK: - Continuous-write cadence (gh#138)

    /// Pins the two constants by value: a silent retune of either turns this
    /// red before it turns the debounce feel wrong on a device.
    func testCadenceConstantsArePinned() {
        XCTAssertEqual(CalendarComposerDraftCadence.debounce, .milliseconds(400))
        XCTAssertEqual(CalendarComposerDraftCadence.maxWait, 2.0)
    }

    func testWriteDecisionGrid() {
        let now = Date(timeIntervalSinceReferenceDate: 900_000_000)

        XCTAssertEqual(
            calendarComposerDraftWriteDecision(lastPersistAt: nil, now: now),
            .writeThrough,
            "no prior write this session (first change) must write through"
        )
        XCTAssertEqual(
            calendarComposerDraftWriteDecision(
                lastPersistAt: now.addingTimeInterval(-(CalendarComposerDraftCadence.maxWait - 0.01)),
                now: now
            ),
            .debounce,
            "just under maxWait must still debounce"
        )
        XCTAssertEqual(
            calendarComposerDraftWriteDecision(
                lastPersistAt: now.addingTimeInterval(-CalendarComposerDraftCadence.maxWait),
                now: now
            ),
            .writeThrough,
            "exactly at maxWait must write through"
        )
        XCTAssertEqual(
            calendarComposerDraftWriteDecision(
                lastPersistAt: now.addingTimeInterval(-CalendarComposerDraftCadence.maxWait - 5),
                now: now
            ),
            .writeThrough,
            "well past maxWait must write through"
        )
    }

    /// R3 (gh#138 review): `wasIdle` is how a caller expresses "this is my
    /// session's first meaningful change" without session-begin bookkeeping.
    /// It must win even when `lastPersistAt` is recent — recent because some
    /// EARLIER, already-ended session wrote a moment ago, which is exactly
    /// the case the old `lastPersistAt = nil` reset used to have to guard
    /// against explicitly.
    func testWriteDecisionWasIdleForcesWriteThroughRegardlessOfElapsed() {
        let now = Date(timeIntervalSinceReferenceDate: 900_000_000)
        XCTAssertEqual(
            calendarComposerDraftWriteDecision(lastPersistAt: now, now: now, wasIdle: true),
            .writeThrough
        )
    }

    // MARK: - Detail composer continuous-write trigger (gh#138)

    /// `savedAt` must never move the trigger — a live `Date()` never equals
    /// itself, so if this regressed, every bare body pass would schedule a
    /// write.
    func testDetailDraftTriggerFieldsEqualIgnoresSavedAt() {
        let a = makeDetailDraft(savedAt: Date(timeIntervalSinceReferenceDate: 100))
        var b = a
        b.savedAt = Date(timeIntervalSinceReferenceDate: 999_999)
        XCTAssertTrue(a.triggerFieldsEqual(b))
    }

    /// `startProgress`/`endProgress` are never restored, so they must never
    /// move the trigger either — otherwise a slider drag would put a
    /// UserDefaults write on a hot path for a value nobody reads back.
    func testDetailDraftTriggerFieldsEqualIgnoresProgress() {
        var a = makeDetailDraft()
        // Deliberately non-zero and distinct from `triggerFieldsEqual`'s
        // freeze value (0) — set explicitly here rather than left to
        // `makeDetailDraft`'s own defaults, so this test's ability to catch
        // a missing freeze line doesn't depend on an unrelated fixture
        // happening to default away from 0.
        a.startProgress = 0.3
        a.endProgress = 0.6
        var b = a
        b.startProgress = 0.1
        b.endProgress = 0.95
        XCTAssertTrue(a.triggerFieldsEqual(b))
    }

    /// Every other field is exactly what the composer's typed/selected
    /// content is made of; each one missing from the trigger would silently
    /// stop scheduling writes for edits to that field.
    func testDetailDraftTriggerFieldsEqualDetectsEveryOtherField() {
        let base = makeDetailDraft()
        var mutations: [(String, CalendarDetailComposerDraft)] = []
        func mutate(_ name: String, _ transform: (inout CalendarDetailComposerDraft) -> Void) {
            var copy = base
            transform(&copy)
            mutations.append((name, copy))
        }
        mutate("mode") { $0.mode = $0.mode == .interrupt ? .parallel : .interrupt }
        mutate("occurrenceKey") { $0.occurrenceKey = "occ-changed" }
        mutate("title") { $0.title = "changed" }
        mutate("typeTitle") { $0.typeTitle = "changed" }
        mutate("note") { $0.note = "changed" }
        mutate("didExplicitlySelectType") { $0.didExplicitlySelectType.toggle() }

        for (name, mutated) in mutations {
            XCTAssertFalse(
                base.triggerFieldsEqual(mutated),
                "changing \(name) must be visible to the continuous-write trigger"
            )
        }
    }

    /// `isOpen` lives outside `CalendarDetailComposerDraft` (the stored
    /// shape has no room for it), so `CalendarDetailComposerDraftFingerprint`'s
    /// own `==` — not `triggerFieldsEqual` — is what has to catch it moving.
    func testDetailComposerFingerprintDetectsIsOpenMoving() {
        let draft = makeDetailDraft()
        let open = CalendarDetailComposerDraftFingerprint(isOpen: true, draft: draft)
        let closed = CalendarDetailComposerDraftFingerprint(isOpen: false, draft: draft)
        XCTAssertNotEqual(open, closed, "composer opening/closing must move the fingerprint")
    }

    /// Regression pin: opening a composer must not itself consume the
    /// session's write-through budget. If this collapse regressed, the
    /// fingerprint would move away from `.idle` the instant a composer
    /// opens — before any typing — and that spurious change would be read
    /// as `wasIdle` (correctly) but would also mean the ACTUAL first
    /// keystroke right after no longer sees `wasIdle`, since the empty-open
    /// change already spent that transition.
    func testFingerprintBuilderCollapsesEmptyDraftToIdle() {
        XCTAssertEqual(
            calendarDetailComposerDraftFingerprint(
                isComposerOpen: true,
                mode: .interrupt,
                isEditingExistingInterrupt: false,
                occurrenceKey: "occ-1",
                title: "  ",
                typeTitle: "Social",
                note: "",
                didExplicitlySelectType: true,
                startProgress: 0.5,
                endProgress: 0.75
            ),
            .idle
        )
    }

    func testFingerprintBuilderKeepsMeaningfulInterruptDraftDistinctFromIdle() {
        XCTAssertNotEqual(
            calendarDetailComposerDraftFingerprint(
                isComposerOpen: true,
                mode: .interrupt,
                isEditingExistingInterrupt: false,
                occurrenceKey: "occ-1",
                title: "Lunch",
                typeTitle: "Social",
                note: "",
                didExplicitlySelectType: true,
                startProgress: 0.5,
                endProgress: 0.75
            ),
            .idle
        )
    }

    /// Proves the `.parallel` switch branch actually runs (as opposed to,
    /// say, an accidental fallthrough to `.note`'s early return).
    func testFingerprintBuilderKeepsMeaningfulParallelDraftDistinctFromIdle() {
        XCTAssertNotEqual(
            calendarDetailComposerDraftFingerprint(
                isComposerOpen: true,
                mode: .parallel,
                isEditingExistingInterrupt: false,
                occurrenceKey: "occ-1",
                title: "Podcast",
                typeTitle: "Leisure",
                note: "",
                didExplicitlySelectType: true,
                startProgress: 0.0,
                endProgress: 1.0
            ),
            .idle
        )
    }

    /// R4 (gh#138 review): before this, the `.note` collapse lived only in
    /// a View computed property, so no test would go red if `.note` started
    /// returning a non-idle fingerprint — every note keystroke would then
    /// schedule a UserDefaults write and the suite would stay green. Pin it
    /// here, with fields that WOULD be meaningful for any other mode, so a
    /// regression that stops special-casing `.note` fails this test.
    func testFingerprintBuilderNoteModeAlwaysIdleEvenWithMeaningfulFields() {
        XCTAssertEqual(
            calendarDetailComposerDraftFingerprint(
                isComposerOpen: true,
                mode: .note,
                isEditingExistingInterrupt: false,
                occurrenceKey: "occ-1",
                title: "should not matter",
                typeTitle: "Social",
                note: "should not matter either",
                didExplicitlySelectType: true,
                startProgress: 0.5,
                endProgress: 0.75
            ),
            .idle
        )
    }

    /// R1 (gh#138 review): `stashDetailComposerDraft` never writes an
    /// edit-existing-interrupt session (its own `editingInterruptID == nil`
    /// guard), so the trigger must collapse to `.idle` for that case too —
    /// otherwise every keystroke while editing an existing interrupt
    /// allocates a `Task`, sleeps 400ms, and writes nothing.
    func testFingerprintBuilderEditingExistingInterruptAlwaysIdleEvenWhenMeaningful() {
        XCTAssertEqual(
            calendarDetailComposerDraftFingerprint(
                isComposerOpen: true,
                mode: .interrupt,
                isEditingExistingInterrupt: true,
                occurrenceKey: "occ-1",
                title: "Standup",
                typeTitle: "Work",
                note: "",
                didExplicitlySelectType: true,
                startProgress: 0.5,
                endProgress: 0.75
            ),
            .idle
        )
    }

    func testFingerprintBuilderClosedComposerAlwaysIdleEvenWhenMeaningful() {
        XCTAssertEqual(
            calendarDetailComposerDraftFingerprint(
                isComposerOpen: false,
                mode: .interrupt,
                isEditingExistingInterrupt: false,
                occurrenceKey: "occ-1",
                title: "Lunch",
                typeTitle: "Social",
                note: "",
                didExplicitlySelectType: true,
                startProgress: 0.5,
                endProgress: 0.75
            ),
            .idle
        )
    }

    /// Every builder test above asserts idle-vs-not-idle only — none of them
    /// would notice a field being dropped on the way into the constructed
    /// draft. If `note` (or any of the others below) were hardcoded inside
    /// `calendarDetailComposerDraftFingerprint` instead of actually reaching
    /// the built draft, every idle/not-idle assertion above would still
    /// pass while a real edit to that field silently stopped scheduling
    /// writes — the `note` case concretely: a note-only edit would then
    /// never persist, and the user's note text could be lost, which is
    /// exactly the defect class gh#138 exists to prevent. Two calls
    /// differing in exactly one parameter must produce unequal fingerprints.
    func testFingerprintBuilderThreadsEveryParameterThroughToTheResult() {
        func build(
            occurrenceKey: String = "occ-1",
            title: String = "Lunch",
            typeTitle: String = "Social",
            note: String = "",
            didExplicitlySelectType: Bool = true
        ) -> CalendarDetailComposerDraftFingerprint {
            calendarDetailComposerDraftFingerprint(
                isComposerOpen: true,
                mode: .interrupt,
                isEditingExistingInterrupt: false,
                occurrenceKey: occurrenceKey,
                title: title,
                typeTitle: typeTitle,
                note: note,
                didExplicitlySelectType: didExplicitlySelectType,
                startProgress: 0.5,
                endProgress: 0.75
            )
        }

        let base = build()
        XCTAssertNotEqual(base, build(occurrenceKey: "occ-2"), "occurrenceKey must reach the built fingerprint")
        XCTAssertNotEqual(base, build(title: "Dinner"), "title must reach the built fingerprint")
        XCTAssertNotEqual(base, build(typeTitle: "Work"), "typeTitle must reach the built fingerprint")
        XCTAssertNotEqual(base, build(note: "bring the umbrella"), "note must reach the built fingerprint")
        XCTAssertNotEqual(
            base, build(didExplicitlySelectType: false),
            "didExplicitlySelectType must reach the built fingerprint"
        )
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

    // MARK: - savedAt preserved on unchanged re-save (gh#184)
    //
    // A restore-then-reopen (detail composer, guaranteed every open via
    // `wasIdle`) or a resume-then-background/swipe-down-without-editing
    // (create/edit composers, via the unconditional scenePhase/onDisappear
    // flush) re-saves content that is already on disk. None of these must
    // restart the 48h `maxAge` clock for a draft nobody actually touched.
    // A real content change must still stamp a fresh `savedAt` — that's
    // what keeps an actively-edited draft's clock extending across a long
    // session, the documented point of `maxAge` at its declaration above.
    //
    // Raw `JSONDecoder` readback (not `loadFresh`) is used for the exact-
    // instant assertions below, deliberately independent of the freshness
    // filtering `loadFresh` itself applies.

    func testDetailDraftReSaveOfIdenticalContentPreservesOriginalSavedAt() {
        let original = makeDetailDraft(title: "Phone call", savedAt: Date(timeIntervalSinceReferenceDate: 1_000_000))
        CalendarDetailComposerDraftStore.save(original, defaults: defaults)

        // Same mode/occurrenceKey/content, as a restore-then-no-edit reopen
        // produces — `stashDetailComposerDraft()` always stamps `Date()`.
        let redundant = makeDetailDraft(title: "Phone call", savedAt: Date(timeIntervalSinceReferenceDate: 2_000_000))
        CalendarDetailComposerDraftStore.save(redundant, defaults: defaults)

        let raw = defaults.data(forKey: CalendarDetailComposerDraftStore.storageKey)!
        let stored = try! JSONDecoder().decode(CalendarDetailComposerDraft.self, from: raw)
        XCTAssertEqual(stored.savedAt, Date(timeIntervalSinceReferenceDate: 1_000_000))
    }

    func testDetailDraftReSaveOfChangedContentStampsFreshSavedAt() {
        let original = makeDetailDraft(title: "Phone call", savedAt: Date(timeIntervalSinceReferenceDate: 1_000_000))
        CalendarDetailComposerDraftStore.save(original, defaults: defaults)

        let edited = makeDetailDraft(title: "Phone call the dentist", savedAt: Date(timeIntervalSinceReferenceDate: 2_000_000))
        CalendarDetailComposerDraftStore.save(edited, defaults: defaults)

        let raw = defaults.data(forKey: CalendarDetailComposerDraftStore.storageKey)!
        let stored = try! JSONDecoder().decode(CalendarDetailComposerDraft.self, from: raw)
        XCTAssertEqual(stored.savedAt, Date(timeIntervalSinceReferenceDate: 2_000_000))
    }

    /// The end-to-end consequence: a draft saved at T and re-saved with
    /// IDENTICAL content at T+47h (an untouched reopen) is still rejected
    /// by `loadFresh` at T+49h — the redundant re-save bought it nothing.
    func testDetailDraftReSavedIdenticallyAt47hStillExpiresAt49hDespiteReSave() {
        let t0 = Date(timeIntervalSinceReferenceDate: 5_000_000)
        CalendarDetailComposerDraftStore.save(
            makeDetailDraft(title: "Phone call", savedAt: t0), defaults: defaults
        )

        let t47 = t0.addingTimeInterval(47 * 60 * 60)
        CalendarDetailComposerDraftStore.save(
            makeDetailDraft(title: "Phone call", savedAt: t47), defaults: defaults
        )

        let t49 = t0.addingTimeInterval(49 * 60 * 60)
        XCTAssertNil(CalendarDetailComposerDraftStore.loadFresh(
            mode: .interrupt, occurrenceKey: "occ-1", now: t49, defaults: defaults
        ))
    }

    /// Twin of the above: a REAL content change at T+47h does extend the
    /// clock, so the draft survives at T+49h — the intended rescue behavior
    /// for a session that's still actively being typed into.
    func testDetailDraftRealContentChangeAt47hSurvivesAt49h() {
        let t0 = Date(timeIntervalSinceReferenceDate: 5_000_000)
        CalendarDetailComposerDraftStore.save(
            makeDetailDraft(title: "Phone call", savedAt: t0), defaults: defaults
        )

        let t47 = t0.addingTimeInterval(47 * 60 * 60)
        CalendarDetailComposerDraftStore.save(
            makeDetailDraft(title: "Phone call the dentist", savedAt: t47), defaults: defaults
        )

        let t49 = t0.addingTimeInterval(49 * 60 * 60)
        XCTAssertNotNil(CalendarDetailComposerDraftStore.loadFresh(
            mode: .interrupt, occurrenceKey: "occ-1", now: t49, defaults: defaults
        ))
    }

    /// An undecodable existing blob (corrupt write, format migration) must
    /// not crash the save or accidentally short-circuit into preserving a
    /// timestamp it never actually decoded — the new draft's own `savedAt`
    /// is used, same as if the slot were empty.
    func testDetailDraftSaveWithUndecodableExistingBlobStillWritesFreshSavedAt() throws {
        defaults.set(Data("not json".utf8), forKey: CalendarDetailComposerDraftStore.storageKey)

        let fresh = makeDetailDraft(title: "Phone call", savedAt: Date(timeIntervalSinceReferenceDate: 1_000_000))
        CalendarDetailComposerDraftStore.save(fresh, defaults: defaults)

        // `try XCTUnwrap`/`XCTUnwrap`-decode rather than `try!`: a mutant that
        // drops the write on an undecodable existing blob leaves the slot
        // holding the OLD corrupt bytes, which must fail this test as a red
        // assertion — a `try!` here would instead trap and abort the whole
        // suite, masking every test after it.
        let raw = try XCTUnwrap(defaults.data(forKey: CalendarDetailComposerDraftStore.storageKey))
        let stored = try XCTUnwrap(try? JSONDecoder().decode(CalendarDetailComposerDraft.self, from: raw))
        XCTAssertEqual(stored.savedAt, Date(timeIntervalSinceReferenceDate: 1_000_000))
    }

    // The create and edit composer twins share `CalendarComposerDraftStore.
    // maxAge`/policy shape but reach a redundant identical-content re-save
    // by a narrower path than the detail composer's guaranteed every-open
    // write: a session resumed from the kill-rescue banner (or a killed
    // edit session) that backgrounds (scenePhase != .active) or is
    // swipe-dismissed WITHOUT further edits still flushes the current
    // (unchanged) snapshot un-debounced. Same shape, same fix.

    func testCreateDraftReSaveOfIdenticalContentPreservesOriginalSavedAt() {
        let original = makeDraft(title: "Dentist", savedAt: Date(timeIntervalSinceReferenceDate: 1_000_000))
        CalendarComposerDraftStore.save(original, defaults: defaults)

        // Copy + re-stamp `savedAt` only, so every other field is
        // byte-identical by construction — exactly what a resumed,
        // untouched session's flush snapshot looks like.
        var redundant = original
        redundant.savedAt = Date(timeIntervalSinceReferenceDate: 2_000_000)
        CalendarComposerDraftStore.save(redundant, defaults: defaults)

        let raw = defaults.data(forKey: CalendarComposerDraftStore.storageKey)!
        let stored = try! JSONDecoder().decode(CalendarComposerDraft.self, from: raw)
        XCTAssertEqual(stored.savedAt, Date(timeIntervalSinceReferenceDate: 1_000_000))
    }

    func testCreateDraftReSaveOfChangedContentStampsFreshSavedAt() {
        let original = makeDraft(title: "Dentist", savedAt: Date(timeIntervalSinceReferenceDate: 1_000_000))
        CalendarComposerDraftStore.save(original, defaults: defaults)

        var edited = original
        edited.title = "Dentist follow-up"
        edited.savedAt = Date(timeIntervalSinceReferenceDate: 2_000_000)
        CalendarComposerDraftStore.save(edited, defaults: defaults)

        let raw = defaults.data(forKey: CalendarComposerDraftStore.storageKey)!
        let stored = try! JSONDecoder().decode(CalendarComposerDraft.self, from: raw)
        XCTAssertEqual(stored.savedAt, Date(timeIntervalSinceReferenceDate: 2_000_000))
    }

    func testEditDraftReSaveOfIdenticalContentPreservesOriginalSavedAt() {
        let id = UUID()
        let base = makeDraft(savedAt: Date(timeIntervalSinceReferenceDate: 500_000))
        let original = makeEditDraft(eventID: id, base: base, savedAt: Date(timeIntervalSinceReferenceDate: 1_000_000))
        CalendarEditDraftStore.save(original, defaults: defaults)

        var redundant = original
        redundant.savedAt = Date(timeIntervalSinceReferenceDate: 2_000_000)
        CalendarEditDraftStore.save(redundant, defaults: defaults)

        let raw = defaults.data(forKey: CalendarEditDraftStore.storageKey)!
        let stored = try! JSONDecoder().decode(CalendarEditDraft.self, from: raw)
        XCTAssertEqual(stored.savedAt, Date(timeIntervalSinceReferenceDate: 1_000_000))
    }

    func testEditDraftReSaveOfChangedContentStampsFreshSavedAt() {
        let id = UUID()
        let base = makeDraft(savedAt: Date(timeIntervalSinceReferenceDate: 500_000))
        let original = makeEditDraft(eventID: id, base: base, savedAt: Date(timeIntervalSinceReferenceDate: 1_000_000))
        CalendarEditDraftStore.save(original, defaults: defaults)

        var edited = original
        edited.edited.title = "Dentist (moved again)"
        edited.savedAt = Date(timeIntervalSinceReferenceDate: 2_000_000)
        CalendarEditDraftStore.save(edited, defaults: defaults)

        let raw = defaults.data(forKey: CalendarEditDraftStore.storageKey)!
        let stored = try! JSONDecoder().decode(CalendarEditDraft.self, from: raw)
        XCTAssertEqual(stored.savedAt, Date(timeIntervalSinceReferenceDate: 2_000_000))
    }

    /// `CalendarEditDraft.fieldsEqual` must ignore all THREE embedded
    /// `savedAt` fields (its own, plus `base`'s and `edited`'s nested
    /// ones) — a moment any of them was written is never part of the
    /// content identity question.
    func testEditDraftFieldsEqualIgnoresAllThreeSavedAtFields() {
        let id = UUID()
        let base = makeDraft(savedAt: Date(timeIntervalSinceReferenceDate: 500_000))
        let a = makeEditDraft(eventID: id, base: base, savedAt: Date(timeIntervalSinceReferenceDate: 1_000_000))
        var b = a
        b.savedAt = Date(timeIntervalSinceReferenceDate: 2_000_000)
        b.base.savedAt = Date(timeIntervalSinceReferenceDate: 3_000_000)
        b.edited.savedAt = Date(timeIntervalSinceReferenceDate: 4_000_000)
        XCTAssertTrue(a.fieldsEqual(b))

        b.edited.title = "changed"
        XCTAssertFalse(a.fieldsEqual(b))
    }
}
